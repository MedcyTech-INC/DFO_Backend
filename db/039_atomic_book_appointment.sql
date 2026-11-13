-- ============================================================
-- Migration 039: Atomic Appointment Booking, Status Management & Rescheduling (Hardened v2.6)
--
-- Security & Concurrency Architecture:
-- 1. Restricted strictly to service_role: public, anon, and authenticated
--    roles are REVOKED from direct execution. Only the NestJS backend
--    executes these functions after verifying JWT, clinic tenancy, and permissions.
-- 2. Explicit function ownership: ALTER FUNCTION ... OWNER TO postgres.
-- 3. Obsolete signatures dropped cleanly with RESTRICT.
-- 4. Complete tenant & ownership verification inside SQL (Doctor, Patient,
--    Lead, Slot, and Leave must all belong to p_clinic_id).
-- 5. Clinic-scoped idempotency via partial unique index on (clinic_id, idempotency_key).
-- 6. Idempotency payload mismatch detection: returns IDEMPOTENCY_PAYLOAD_MISMATCH
--    if an existing key is reused with a different booking request.
-- 7. Atomic single-transaction slot reservation with row-level locks (FOR UPDATE).
-- 8. Atomic single-transaction status update and slot release with zero floor protection.
-- 9. Atomic single-transaction rescheduling: validates same-slot requests, protects end_time,
--    and locks distinct slots in deterministic monotonic order to minimize deadlock risk.
-- 10. Strict state machine transition validation (Scheduled -> Checked-In -> In-Consultation -> Completed).
-- 11. Strict immutability for finalized states (Completed, Canceled, No Show).
-- 12. Zero capacity alterations on past historical dates.
--
-- Migration Safety: 100% idempotent. Safe to execute multiple times.
-- DO NOT EXECUTE DIRECTLY AGAINST PRODUCTION WITHOUT SEPARATE APPROVAL.
-- ============================================================

-- Step 1: Add idempotency_key column and clinic-scoped unique index safely
ALTER TABLE IF EXISTS opdesk_sakhi_clinic_appointments 
ADD COLUMN IF NOT EXISTS idempotency_key UUID;

-- Defensive deduplication check: If duplicate non-null (clinic_id, idempotency_key) pairs somehow exist
-- from previous tests or dirty data, retain only the earliest row and nullify the rest so unique index creation never fails
DO $$
BEGIN
    IF EXISTS (
        SELECT clinic_id, idempotency_key 
        FROM opdesk_sakhi_clinic_appointments 
        WHERE idempotency_key IS NOT NULL 
        GROUP BY clinic_id, idempotency_key 
        HAVING COUNT(*) > 1
    ) THEN
        RAISE WARNING 'Duplicate non-null (clinic_id, idempotency_key) values detected. Resolving before index creation.';
        WITH duplicates AS (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY clinic_id, idempotency_key ORDER BY created_at ASC) as rn
            FROM opdesk_sakhi_clinic_appointments
            WHERE idempotency_key IS NOT NULL
        )
        UPDATE opdesk_sakhi_clinic_appointments
        SET idempotency_key = NULL
        WHERE id IN (SELECT id FROM duplicates WHERE rn > 1);
    END IF;
END $$;

DROP INDEX IF EXISTS idx_appointments_idempotency_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_clinic_idempotency_key 
ON opdesk_sakhi_clinic_appointments(clinic_id, idempotency_key) 
WHERE idempotency_key IS NOT NULL;


-- Step 2: Drop obsolete overloads cleanly (with RESTRICT to guarantee no dependent objects exist)
DROP FUNCTION IF EXISTS book_appointment_atomic(UUID, UUID, DATE, TIME, TIME, JSONB) RESTRICT;


-- ============================================================
-- Function 1: book_appointment_atomic
-- ============================================================
CREATE OR REPLACE FUNCTION book_appointment_atomic(
    p_clinic_id UUID,
    p_doctor_id UUID,
    p_appointment_date DATE,
    p_start_time TIME,
    p_end_time TIME,
    p_payload JSONB,
    p_idempotency_key UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_slot RECORD;
    v_appointment RECORD;
    v_new_booked_count INT;
    v_new_status VARCHAR(20);
    v_patient_id UUID;
    v_lead_id UUID;
    v_resource_id TEXT;
    v_appt_type VARCHAR(50);
    v_appt_status VARCHAR(50);
    v_queue_status VARCHAR(50);
    v_end_time TIME;
BEGIN
    -- Extract patient, lead, and resource identifiers early for verification
    v_patient_id := NULLIF(p_payload->>'patient_id', '')::UUID;
    v_lead_id := NULLIF(p_payload->>'lead_id', '')::UUID;
    v_resource_id := NULLIF(p_payload->>'resource_id', '');

    -- 1. True Request Idempotency with Advisory Lock & Payload Mismatch Check:
    IF p_idempotency_key IS NOT NULL THEN
        -- Acquire transaction-level advisory lock hashed from clinic_id and idempotency_key
        PERFORM pg_advisory_xact_lock(hashtext(p_clinic_id::text || ':' || p_idempotency_key::text));

        SELECT * INTO v_appointment
        FROM opdesk_sakhi_clinic_appointments
        WHERE clinic_id = p_clinic_id AND idempotency_key = p_idempotency_key;

        IF FOUND THEN
            -- Exhaustive validation of all booking-relevant parameters and payload fields
            IF v_appointment.doctor_id <> p_doctor_id 
               OR v_appointment.appointment_date <> p_appointment_date 
               OR v_appointment.start_time <> p_start_time 
               OR (p_end_time IS NOT NULL AND v_appointment.end_time IS DISTINCT FROM p_end_time)
               OR v_appointment.patient_id IS DISTINCT FROM v_patient_id 
               OR v_appointment.lead_id IS DISTINCT FROM v_lead_id 
               OR NULLIF(v_appointment.resource_id, '') IS DISTINCT FROM v_resource_id
               OR NULLIF(v_appointment.type, '') IS DISTINCT FROM NULLIF(p_payload->>'type', '')
               OR NULLIF(v_appointment.visit_reason, '') IS DISTINCT FROM NULLIF(p_payload->>'visit_reason', '')
               OR NULLIF(v_appointment.patient_name_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_name_snapshot', '')
               OR NULLIF(v_appointment.patient_phone_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_phone_snapshot', '')
               OR NULLIF(v_appointment.sex_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'sex_snapshot', '')
               OR NULLIF(v_appointment.patient_email_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_email_snapshot', '')
               OR NULLIF(v_appointment.patient_dob_snapshot::text, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_dob_snapshot', '')
               OR NULLIF(v_appointment.patient_age_snapshot::text, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_age_snapshot', '')
               OR NULLIF(v_appointment.patient_address_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_address_snapshot', '')
               OR NULLIF(v_appointment.patient_postal_code_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_postal_code_snapshot', '')
               OR NULLIF(v_appointment.patient_marital_status_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'patient_marital_status_snapshot', '')
               OR NULLIF(v_appointment.doctor_name_snapshot, '') IS DISTINCT FROM NULLIF(p_payload->>'doctor_name_snapshot', '')
               OR NULLIF(v_appointment.source, '') IS DISTINCT FROM NULLIF(p_payload->>'source', '')
               OR NULLIF(v_appointment.referral_doctor, '') IS DISTINCT FROM NULLIF(p_payload->>'referral_doctor', '')
               OR NULLIF(v_appointment.referral_doctor_phone, '') IS DISTINCT FROM NULLIF(p_payload->>'referral_doctor_phone', '')
               OR NULLIF(v_appointment.referral_notes, '') IS DISTINCT FROM NULLIF(p_payload->>'referral_notes', '') THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'code', 'IDEMPOTENCY_PAYLOAD_MISMATCH',
                    'error', 'The provided idempotency key has already been used for a different appointment booking'
                );
            END IF;

            RETURN jsonb_build_object(
                'success', true,
                'data', row_to_json(v_appointment),
                'idempotent', true
            );
        END IF;
    END IF;

    -- 2. Tenant & Doctor Verification: Doctor must exist in this clinic, have role Doctor, and be active
    IF NOT EXISTS (
        SELECT 1 FROM opdesk_sakhi_clinic_users
        WHERE id = p_doctor_id 
          AND clinic_id = p_clinic_id 
          AND role = 'Doctor'
          AND is_active = true
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_DOCTOR',
            'error', 'Doctor not found in this clinic or clinician account is inactive'
        );
    END IF;

    -- 3. Doctor Leave Check: Doctor must not be on approved leave on the requested date
    IF EXISTS (
        SELECT 1 FROM opdesk_sakhi_clinic_doctor_leaves
        WHERE doctor_id = p_doctor_id 
          AND clinic_id = p_clinic_id 
          AND leave_date = p_appointment_date
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'DOCTOR_ON_LEAVE',
            'error', 'Doctor is on approved leave on this date'
        );
    END IF;

    -- 4. Tenant Patient / Lead Ownership Verification
    IF v_patient_id IS NULL AND v_lead_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PATIENT_OR_LEAD_REQUIRED',
            'error', 'Either patient_id or lead_id is required to book an appointment'
        );
    END IF;

    IF v_patient_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM opdesk_sakhi_clinic_patients
            WHERE id = v_patient_id AND clinic_id = p_clinic_id
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'INVALID_PATIENT',
                'error', 'Patient not found in this clinic or unauthorized patient access'
            );
        END IF;
    END IF;

    IF v_lead_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM opdesk_sakhi_clinic_leads
            WHERE id = v_lead_id AND clinic_id = p_clinic_id
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'INVALID_LEAD',
                'error', 'Lead not found in this clinic or unauthorized lead access'
            );
        END IF;
    END IF;

    -- 5. Row-Level Lock on Availability Slot (prevents concurrent double-booking and race conditions)
    SELECT id, clinic_id, doctor_id, capacity, booked_count, status, start_time, end_time INTO v_slot
    FROM opdesk_sakhi_clinic_availability_slots
    WHERE clinic_id = p_clinic_id
      AND doctor_id = p_doctor_id
      AND slot_date = p_appointment_date
      AND start_time = p_start_time
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_NOT_FOUND',
            'error', 'Selected appointment slot does not exist for this doctor and date'
        );
    END IF;

    IF v_slot.status <> 'AVAILABLE' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_UNAVAILABLE',
            'error', 'Selected time slot is blocked or unavailable'
        );
    END IF;

    IF v_slot.booked_count >= v_slot.capacity THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_CAPACITY_EXCEEDED',
            'error', 'Slot capacity has been filled. Please choose another time.'
        );
    END IF;

    -- 6. End Time Validation: Guarantee end_time matches configured slot duration
    v_end_time := COALESCE(p_end_time, v_slot.end_time);
    IF p_end_time IS NOT NULL AND p_end_time <> v_slot.end_time THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_END_TIME',
            'error', 'Appointment end time does not match the configured slot duration'
        );
    END IF;

    -- 7. Secondary Duplicate Check: Prevent duplicate active bookings for the same patient/doctor/slot
    IF v_patient_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM opdesk_sakhi_clinic_appointments
            WHERE clinic_id = p_clinic_id
              AND doctor_id = p_doctor_id
              AND patient_id = v_patient_id
              AND appointment_date = p_appointment_date
              AND start_time = p_start_time
              AND status NOT IN ('Canceled', 'No Show')
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'DUPLICATE_APPOINTMENT',
                'error', 'This patient already has an active appointment with this doctor at the selected time'
            );
        END IF;
    END IF;

    -- 8. Status & Type Normalization
    v_appt_type := COALESCE(NULLIF(p_payload->>'type', ''), 'Consultation');
    IF v_appt_type NOT IN ('Consultation', 'Follow-up', 'Procedure', 'Emergency', 'Scan', 'Surgery', 'Camp') THEN
        v_appt_type := 'Consultation';
    END IF;

    v_appt_status := COALESCE(NULLIF(p_payload->>'status', ''), 'Scheduled');
    IF v_appt_status NOT IN ('Scheduled', 'Arrived', 'Checked-In', 'Expected') THEN
        v_appt_status := 'Scheduled';
    END IF;

    v_queue_status := CASE 
        WHEN v_appt_status = 'Checked-In' THEN 'WAITING'
        WHEN v_appt_status = 'Arrived' THEN 'ARRIVED'
        ELSE 'SCHEDULED'
    END;

    -- 9. Atomically Increment Slot Counter and Set Status
    v_new_booked_count := v_slot.booked_count + 1;
    v_new_status := CASE WHEN v_new_booked_count >= v_slot.capacity THEN 'BOOKED' ELSE 'AVAILABLE' END;

    UPDATE opdesk_sakhi_clinic_availability_slots
    SET booked_count = v_new_booked_count,
        status = v_new_status,
        updated_at = NOW()
    WHERE id = v_slot.id;

    -- 10. Atomically Insert Master Appointment Record (idempotency_key explicitly stored)
    INSERT INTO opdesk_sakhi_clinic_appointments (
        clinic_id,
        doctor_id,
        patient_id,
        lead_id,
        appointment_date,
        start_time,
        end_time,
        type,
        status,
        queue_status,
        visit_reason,
        resource_id,
        idempotency_key,
        patient_name_snapshot,
        sex_snapshot,
        doctor_name_snapshot,
        patient_phone_snapshot,
        patient_dob_snapshot,
        patient_email_snapshot,
        patient_address_snapshot,
        patient_postal_code_snapshot,
        patient_marital_status_snapshot,
        patient_age_snapshot,
        source,
        referral_doctor,
        referral_doctor_phone,
        referral_notes,
        created_at
    ) VALUES (
        p_clinic_id,
        p_doctor_id,
        v_patient_id,
        v_lead_id,
        p_appointment_date,
        p_start_time,
        v_end_time,
        v_appt_type,
        v_appt_status,
        v_queue_status,
        p_payload->>'visit_reason',
        v_resource_id,
        p_idempotency_key,
        p_payload->>'patient_name_snapshot',
        p_payload->>'sex_snapshot',
        p_payload->>'doctor_name_snapshot',
        p_payload->>'patient_phone_snapshot',
        p_payload->>'patient_dob_snapshot',
        p_payload->>'patient_email_snapshot',
        p_payload->>'patient_address_snapshot',
        p_payload->>'patient_postal_code_snapshot',
        p_payload->>'patient_marital_status_snapshot',
        p_payload->>'patient_age_snapshot',
        p_payload->>'source',
        p_payload->>'referral_doctor',
        p_payload->>'referral_doctor_phone',
        p_payload->>'referral_notes',
        NOW()
    ) RETURNING * INTO v_appointment;

    RETURN jsonb_build_object(
        'success', true,
        'data', row_to_json(v_appointment)
    );
END;
$$;

-- Ownership & Permissions for book_appointment_atomic
ALTER FUNCTION book_appointment_atomic(UUID, UUID, DATE, TIME, TIME, JSONB, UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION book_appointment_atomic(UUID, UUID, DATE, TIME, TIME, JSONB, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION book_appointment_atomic(UUID, UUID, DATE, TIME, TIME, JSONB, UUID) TO service_role;


-- ============================================================
-- Function 2: update_appointment_status_atomic
-- ============================================================
CREATE OR REPLACE FUNCTION update_appointment_status_atomic(
    p_clinic_id UUID,
    p_appointment_id UUID,
    p_new_status VARCHAR,
    p_cancellation_reason TEXT DEFAULT NULL,
    p_cancelled_at TIMESTAMPTZ DEFAULT NULL,
    p_token_number VARCHAR DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_appt RECORD;
    v_slot RECORD;
    v_new_booked_count INT;
    v_new_slot_status VARCHAR(20);
    v_queue_status VARCHAR(50);
    v_slot_released BOOLEAN := false;
    v_slot_warning TEXT := NULL;
BEGIN
    -- 1. Lock the appointment row FOR UPDATE to serialize concurrent status changes
    SELECT * INTO v_appt
    FROM opdesk_sakhi_clinic_appointments
    WHERE id = p_appointment_id AND clinic_id = p_clinic_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'APPOINTMENT_NOT_FOUND',
            'error', 'Appointment not found'
        );
    END IF;

    -- 2. Strict Immutability: Once finalized, an appointment cannot be updated
    IF v_appt.status IN ('Completed', 'Canceled', 'No Show') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'STATUS_IMMUTABLE',
            'error', format('Cannot update a finalized appointment (current status: %s)', v_appt.status)
        );
    END IF;

    -- 3. Strict Permitted State Transition Validation (Identical to NestJS ALLOWED_TRANSITIONS)
    IF (v_appt.status IN ('Scheduled', 'Expected') AND p_new_status NOT IN ('Arrived', 'Checked-In', 'Canceled', 'No Show'))
       OR (v_appt.status = 'Arrived' AND p_new_status NOT IN ('Checked-In', 'In-Consultation', 'Canceled', 'No Show'))
       OR (v_appt.status = 'Checked-In' AND p_new_status NOT IN ('In-Consultation', 'Canceled', 'No Show'))
       OR (v_appt.status = 'In-Consultation' AND p_new_status NOT IN ('Completed', 'Canceled'))
       OR (v_appt.status NOT IN ('Scheduled', 'Expected', 'Arrived', 'Checked-In', 'In-Consultation')) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_STATUS_TRANSITION',
            'error', format('Invalid status transition from ''%s'' to ''%s''. Permitted transitions: %s', 
                     v_appt.status, 
                     p_new_status,
                     CASE v_appt.status
                         WHEN 'Scheduled' THEN 'Arrived, Checked-In, Canceled, No Show'
                         WHEN 'Expected' THEN 'Arrived, Checked-In, Canceled, No Show'
                         WHEN 'Arrived' THEN 'Checked-In, In-Consultation, Canceled, No Show'
                         WHEN 'Checked-In' THEN 'In-Consultation, Canceled, No Show'
                         WHEN 'In-Consultation' THEN 'Completed, Canceled'
                         ELSE 'None'
                     END)
        );
    END IF;

    -- 4. Exhaustive target queue_status mapping
    v_queue_status := CASE 
        WHEN p_new_status = 'Checked-In' THEN 'WAITING'
        WHEN p_new_status = 'In-Consultation' THEN 'IN_CONSULTATION'
        WHEN p_new_status = 'Completed' THEN 'COMPLETED'
        WHEN p_new_status = 'Canceled' THEN 'CANCELED'
        WHEN p_new_status = 'No Show' THEN 'NO_SHOW'
        WHEN p_new_status = 'Arrived' THEN 'ARRIVED'
        WHEN p_new_status IN ('Scheduled', 'Expected') THEN 'SCHEDULED'
        ELSE 'SCHEDULED'
    END;

    -- 5. Update the appointment record
    UPDATE opdesk_sakhi_clinic_appointments
    SET status = p_new_status,
        queue_status = v_queue_status,
        token_number = COALESCE(p_token_number, token_number),
        cancellation_reason = CASE WHEN p_new_status = 'Canceled' THEN COALESCE(p_cancellation_reason, 'Cancelled by clinic') ELSE cancellation_reason END,
        cancelled_at = CASE WHEN p_new_status = 'Canceled' THEN COALESCE(p_cancelled_at, NOW()) ELSE cancelled_at END
    WHERE id = v_appt.id;

    -- 6. Atomic Slot Capacity Release:
    -- Decrement slot only if transitioning to Canceled or No Show AND appointment date is today or future
    IF p_new_status IN ('Canceled', 'No Show') AND v_appt.appointment_date >= CURRENT_DATE AND v_appt.doctor_id IS NOT NULL THEN
        -- Lock slot row FOR UPDATE
        SELECT id, capacity, booked_count, status INTO v_slot
        FROM opdesk_sakhi_clinic_availability_slots
        WHERE clinic_id = p_clinic_id
          AND doctor_id = v_appt.doctor_id
          AND slot_date = v_appt.appointment_date
          AND start_time = v_appt.start_time
        FOR UPDATE;

        IF FOUND THEN
            IF v_slot.booked_count > 0 THEN
                v_new_booked_count := v_slot.booked_count - 1;
                v_new_slot_status := CASE WHEN v_new_booked_count >= v_slot.capacity THEN 'BOOKED' ELSE 'AVAILABLE' END;

                UPDATE opdesk_sakhi_clinic_availability_slots
                SET booked_count = v_new_booked_count,
                    status = v_new_slot_status,
                    updated_at = NOW()
                WHERE id = v_slot.id;

                v_slot_released := true;
            ELSE
                -- booked_count is already 0: protect against underflow; ensure status reflects availability
                IF v_slot.status = 'BOOKED' THEN
                    UPDATE opdesk_sakhi_clinic_availability_slots
                    SET status = 'AVAILABLE',
                        updated_at = NOW()
                    WHERE id = v_slot.id;
                END IF;
                v_slot_released := false;
                v_slot_warning := 'Slot booked_count was already 0';
            END IF;
        ELSE
            -- Slot row is missing (e.g. ad-hoc booking without an underlying availability slot)
            v_slot_released := false;
            v_slot_warning := 'No corresponding availability slot found for doctor, date, and start_time';
        END IF;
    END IF;

    -- 7. Fetch and return updated appointment record
    SELECT * INTO v_appt FROM opdesk_sakhi_clinic_appointments WHERE id = p_appointment_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', row_to_json(v_appt),
        'slot_released', v_slot_released,
        'slot_warning', v_slot_warning
    );
END;
$$;

-- Ownership & Permissions for update_appointment_status_atomic
ALTER FUNCTION update_appointment_status_atomic(UUID, UUID, VARCHAR, TEXT, TIMESTAMPTZ, VARCHAR) OWNER TO postgres;
REVOKE ALL ON FUNCTION update_appointment_status_atomic(UUID, UUID, VARCHAR, TEXT, TIMESTAMPTZ, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION update_appointment_status_atomic(UUID, UUID, VARCHAR, TEXT, TIMESTAMPTZ, VARCHAR) TO service_role;


-- ============================================================
-- Function 3: reschedule_appointment_atomic
-- ============================================================
CREATE OR REPLACE FUNCTION reschedule_appointment_atomic(
    p_clinic_id UUID,
    p_appointment_id UUID,
    p_new_doctor_id UUID,
    p_new_date DATE,
    p_new_start_time TIME,
    p_new_end_time TIME DEFAULT NULL,
    p_rescheduled_by UUID DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_appt RECORD;
    v_locked_slot RECORD;
    v_old_slot RECORD;
    v_new_slot RECORD;
    v_is_same_slot BOOLEAN;
    v_new_booked_count INT;
    v_new_slot_status VARCHAR(20);
    v_new_doctor_name TEXT;
    v_end_time TIME;
BEGIN
    -- 1. Lock appointment row FOR UPDATE
    SELECT * INTO v_appt
    FROM opdesk_sakhi_clinic_appointments
    WHERE id = p_appointment_id AND clinic_id = p_clinic_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'APPOINTMENT_NOT_FOUND',
            'error', 'Appointment not found'
        );
    END IF;

    -- 2. Strict Immutability: Once finalized, an appointment cannot be rescheduled
    IF v_appt.status IN ('Completed', 'Canceled', 'No Show') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'STATUS_IMMUTABLE',
            'error', format('Cannot reschedule a finalized appointment (current status: %s)', v_appt.status)
        );
    END IF;

    -- 3. Date Validation: Cannot reschedule to past dates
    IF p_new_date < CURRENT_DATE THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_DATE',
            'error', 'appointment_date cannot be in the past'
        );
    END IF;

    -- 4. Target Doctor & Tenant Validation
    SELECT TRIM(CONCAT(first_name, ' ', last_name)) INTO v_new_doctor_name
    FROM opdesk_sakhi_clinic_users
    WHERE id = p_new_doctor_id 
      AND clinic_id = p_clinic_id 
      AND role = 'Doctor'
      AND is_active = true;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_DOCTOR',
            'error', 'Selected doctor not found in this clinic or clinician account is inactive'
        );
    END IF;

    -- 5. Doctor Leave Check on target date
    IF EXISTS (
        SELECT 1 FROM opdesk_sakhi_clinic_doctor_leaves
        WHERE doctor_id = p_new_doctor_id 
          AND clinic_id = p_clinic_id 
          AND leave_date = p_new_date
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'DOCTOR_ON_LEAVE',
            'error', 'Doctor is on approved leave on the target date'
        );
    END IF;

    -- 6. Check if rescheduling to the EXACT SAME slot
    v_is_same_slot := (
        v_appt.doctor_id = p_new_doctor_id AND
        v_appt.appointment_date = p_new_date AND
        v_appt.start_time = p_new_start_time
    );

    IF v_is_same_slot THEN
        -- Strictly validate that the slot actually exists for this doctor and clinic
        SELECT id, capacity, booked_count, status, start_time, end_time INTO v_new_slot
        FROM opdesk_sakhi_clinic_availability_slots
        WHERE clinic_id = p_clinic_id
          AND doctor_id = p_new_doctor_id
          AND slot_date = p_new_date
          AND start_time = p_new_start_time
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'SLOT_NOT_FOUND',
                'error', 'Selected appointment slot does not exist for this doctor and date'
            );
        END IF;

        IF v_new_slot.status NOT IN ('AVAILABLE', 'BOOKED') THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'SLOT_UNAVAILABLE',
                'error', format('Selected time slot cannot be rescheduled into because its status is %s', v_new_slot.status)
            );
        END IF;

        -- Validate end_time against slot's configured end_time
        IF p_new_end_time IS NOT NULL AND p_new_end_time <> v_new_slot.end_time THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'INVALID_END_TIME',
                'error', 'Appointment end time does not match configured slot duration'
            );
        END IF;

        v_end_time := COALESCE(p_new_end_time, v_new_slot.end_time);

        -- Update appointment metadata and validated end_time without altering slot capacity
        UPDATE opdesk_sakhi_clinic_appointments
        SET end_time = v_end_time,
            visit_reason = COALESCE(p_notes, visit_reason)
        WHERE id = v_appt.id
        RETURNING * INTO v_appt;

        RETURN jsonb_build_object(
            'success', true,
            'data', row_to_json(v_appt),
            'same_slot', true
        );
    END IF;

    -- 7. Distinct Slot Rescheduling:
    -- Query and lock both old slot and new slot ordered consistently by (slot_date, doctor_id, start_time)
    -- to minimize deadlock probability between concurrent requests
    FOR v_locked_slot IN
        SELECT id, doctor_id, slot_date, start_time, end_time, capacity, booked_count, status
        FROM opdesk_sakhi_clinic_availability_slots
        WHERE clinic_id = p_clinic_id
          AND (
            (doctor_id = v_appt.doctor_id AND slot_date = v_appt.appointment_date AND start_time = v_appt.start_time)
            OR
            (doctor_id = p_new_doctor_id AND slot_date = p_new_date AND start_time = p_new_start_time)
          )
        ORDER BY slot_date ASC, doctor_id ASC, start_time ASC
        FOR UPDATE
    LOOP
        IF v_locked_slot.doctor_id = p_new_doctor_id 
           AND v_locked_slot.slot_date = p_new_date 
           AND v_locked_slot.start_time = p_new_start_time THEN
            v_new_slot := v_locked_slot;
        END IF;

        IF v_appt.doctor_id IS NOT NULL 
           AND v_locked_slot.doctor_id = v_appt.doctor_id 
           AND v_locked_slot.slot_date = v_appt.appointment_date 
           AND v_locked_slot.start_time = v_appt.start_time THEN
            v_old_slot := v_locked_slot;
        END IF;
    END LOOP;

    -- 8. Validate New Slot Availability & Capacity
    IF v_new_slot.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_NOT_FOUND',
            'error', 'Selected new appointment slot does not exist for this doctor and date'
        );
    END IF;

    IF v_new_slot.status <> 'AVAILABLE' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_UNAVAILABLE',
            'error', 'Selected new time slot is blocked or unavailable'
        );
    END IF;

    IF v_new_slot.booked_count >= v_new_slot.capacity THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'SLOT_CAPACITY_EXCEEDED',
            'error', 'The new slot capacity has been filled. Please choose another time.'
        );
    END IF;

    IF p_new_end_time IS NOT NULL AND p_new_end_time <> v_new_slot.end_time THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_END_TIME',
            'error', 'Appointment end time does not match configured slot duration'
        );
    END IF;

    v_end_time := COALESCE(p_new_end_time, v_new_slot.end_time);

    -- 9. Atomic Release of Old Slot Capacity (only if old appointment date is today or future)
    IF v_old_slot.id IS NOT NULL AND v_old_slot.booked_count > 0 AND v_appt.appointment_date >= CURRENT_DATE THEN
        v_new_booked_count := v_old_slot.booked_count - 1;
        v_new_slot_status := CASE WHEN v_new_booked_count >= v_old_slot.capacity THEN 'BOOKED' ELSE 'AVAILABLE' END;

        UPDATE opdesk_sakhi_clinic_availability_slots
        SET booked_count = v_new_booked_count,
            status = v_new_slot_status,
            updated_at = NOW()
        WHERE id = v_old_slot.id;
    END IF;

    -- 10. Atomic Reservation of New Slot Capacity
    v_new_booked_count := v_new_slot.booked_count + 1;
    v_new_slot_status := CASE WHEN v_new_booked_count >= v_new_slot.capacity THEN 'BOOKED' ELSE 'AVAILABLE' END;

    UPDATE opdesk_sakhi_clinic_availability_slots
    SET booked_count = v_new_booked_count,
        status = v_new_slot_status,
        updated_at = NOW()
    WHERE id = v_new_slot.id;

    -- 11. Atomic Master Appointment Record Update
    UPDATE opdesk_sakhi_clinic_appointments
    SET doctor_id = p_new_doctor_id,
        appointment_date = p_new_date,
        start_time = p_new_start_time,
        end_time = v_end_time,
        doctor_name_snapshot = COALESCE(NULLIF(v_new_doctor_name, ''), doctor_name_snapshot),
        visit_reason = COALESCE(p_notes, visit_reason)
    WHERE id = v_appt.id
    RETURNING * INTO v_appt;

    RETURN jsonb_build_object(
        'success', true,
        'data', row_to_json(v_appt)
    );
END;
$$;

-- Ownership & Permissions for reschedule_appointment_atomic
ALTER FUNCTION reschedule_appointment_atomic(UUID, UUID, UUID, DATE, TIME, TIME, UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION reschedule_appointment_atomic(UUID, UUID, UUID, DATE, TIME, TIME, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION reschedule_appointment_atomic(UUID, UUID, UUID, DATE, TIME, TIME, UUID, TEXT) TO service_role;
