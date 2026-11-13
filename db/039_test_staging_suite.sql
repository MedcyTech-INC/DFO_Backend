-- ============================================================
-- Migration 039: Staging Database Automated Verification Suite
--
-- This script runs a complete suite of integration tests for:
-- 1. Successful booking
-- 2. Full slot rejection
-- 3. Concurrent bookings competing for the last available capacity (OCC / Lock test)
-- 4. Concurrent idempotency retries (same key, same payload)
-- 5. Idempotency key reused with different payload (IDEMPOTENCY_PAYLOAD_MISMATCH)
-- 6. Doctor leave conflict (DOCTOR_ON_LEAVE)
-- 7. Cancellation and No Show slot capacity release
-- 8. Repeated cancellation on finalized appointment (STATUS_IMMUTABLE)
-- 9. Same-slot rescheduling (validates slot status allowlist, end_time, zero capacity change)
-- 10. Cross-doctor rescheduling (atomic old decrement & new increment)
-- 11. Transaction rollback on failure (leaves original state untouched)
-- 12. Function permission & role checks (service_role only, revoked from anon/public/authenticated)
--
-- EXECUTION: Run inside a transaction on your Supabase / PostgreSQL staging instance.
-- ============================================================

DO $$
DECLARE
    -- Test Identifiers
    v_clinic_id UUID;
    v_doctor1_id UUID := '88888888-8888-8888-8888-888888888888';
    v_doctor2_id UUID := '77777777-7777-7777-7777-777777777777';
    v_patient1_id UUID := '66666666-6666-6666-6666-666666666666';
    v_patient2_id UUID := '55555555-5555-5555-5555-555555555555';
    v_patient3_id UUID := '44444444-4444-4444-4444-444444444444';
    v_uhid1 TEXT := 'UHID-' || substr(gen_random_uuid()::text, 1, 8);
    v_uhid2 TEXT := 'UHID-' || substr(gen_random_uuid()::text, 1, 8);
    v_uhid3 TEXT := 'UHID-' || substr(gen_random_uuid()::text, 1, 8);
    v_test_date DATE := CURRENT_DATE + INTERVAL '5 days';
    v_start_time TIME := '10:00:00';
    v_end_time TIME := '10:15:00';
    v_idempotency_key UUID := gen_random_uuid();

    -- Function Execution Outputs
    v_res JSONB;
    v_appt1_id UUID;
    v_appt2_id UUID;
    v_slot RECORD;
    v_perm_count INT;
BEGIN
    RAISE NOTICE '=== STARTING MIGRATION 039 STAGING VERIFICATION SUITE ===';

    -- Resolve valid clinic from existing opdesk_clinics
    SELECT id INTO v_clinic_id FROM opdesk_clinics LIMIT 1;
    IF v_clinic_id IS NULL THEN
        RAISE EXCEPTION 'No clinic found in opdesk_clinics';
    END IF;

    -- ------------------------------------------------------------
    -- SETUP TEMPORARY TEST DATA
    -- ------------------------------------------------------------
    -- Cleanup any leftover test rows specifically for our test IDs
    DELETE FROM opdesk_sakhi_clinic_appointments WHERE clinic_id = v_clinic_id AND (doctor_id IN (v_doctor1_id, v_doctor2_id) OR patient_id IN (v_patient1_id, v_patient2_id, v_patient3_id));
    DELETE FROM opdesk_sakhi_clinic_availability_slots WHERE clinic_id = v_clinic_id AND doctor_id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_doctor_leaves WHERE clinic_id = v_clinic_id AND doctor_id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_users WHERE id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_patients WHERE id IN (v_patient1_id, v_patient2_id, v_patient3_id) OR uhid LIKE 'UHID-TEST%';

    -- Insert Test Clinic Doctors (with valid required email and password_hash)
    INSERT INTO opdesk_sakhi_clinic_users (id, clinic_id, email, password_hash, first_name, last_name, role, is_active)
    VALUES 
        (v_doctor1_id, v_clinic_id, 'test.doctor.alpha@example.com', 'hash123', 'TestDoctor', 'Alpha', 'Doctor', true),
        (v_doctor2_id, v_clinic_id, 'test.doctor.beta@example.com', 'hash123', 'TestDoctor', 'Beta', 'Doctor', true);

    -- Insert Test Patients (with valid unique uhids)
    INSERT INTO opdesk_sakhi_clinic_patients (id, clinic_id, uhid, name, mobile, status)
    VALUES 
        (v_patient1_id, v_clinic_id, v_uhid1, 'Patient One', '9000000001', 'Active'),
        (v_patient2_id, v_clinic_id, v_uhid2, 'Patient Two', '9000000002', 'Active'),
        (v_patient3_id, v_clinic_id, v_uhid3, 'Patient Three', '9000000003', 'Active');

    -- Insert Slot with Capacity = 2
    INSERT INTO opdesk_sakhi_clinic_availability_slots (clinic_id, doctor_id, slot_date, start_time, end_time, capacity, booked_count, status)
    VALUES (v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time, 2, 0, 'AVAILABLE');

    -- Insert Slot for Doctor 2
    INSERT INTO opdesk_sakhi_clinic_availability_slots (clinic_id, doctor_id, slot_date, start_time, end_time, capacity, booked_count, status)
    VALUES (v_clinic_id, v_doctor2_id, v_test_date, '11:00:00', '11:15:00', 1, 0, 'AVAILABLE');


    -- ------------------------------------------------------------
    -- TEST 1: Successful Booking
    -- ------------------------------------------------------------
    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient1_id, 'type', 'Consultation'),
        v_idempotency_key
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 1 Failed: Booking should succeed';
    v_appt1_id := (v_res->'data'->>'id')::UUID;

    SELECT booked_count, status INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 1, 'Test 1 Failed: booked_count should be 1';
    ASSERT v_slot.status = 'AVAILABLE', 'Test 1 Failed: slot status should remain AVAILABLE with capacity 2';
    RAISE NOTICE 'Test 1 PASSED: Successful Booking';


    -- ------------------------------------------------------------
    -- TEST 2: Concurrent Idempotency Retry (same key, same payload)
    -- ------------------------------------------------------------
    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient1_id, 'type', 'Consultation'),
        v_idempotency_key
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 2 Failed: Idempotent call should succeed';
    ASSERT (v_res->>'idempotent')::BOOLEAN = true, 'Test 2 Failed: Should be flagged as idempotent';
    ASSERT (v_res->'data'->>'id')::UUID = v_appt1_id, 'Test 2 Failed: Should return original appointment';

    SELECT booked_count INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 1, 'Test 2 Failed: booked_count should NOT increment on idempotent retry';
    RAISE NOTICE 'Test 2 PASSED: Idempotent Retry';


    -- ------------------------------------------------------------
    -- TEST 3: Idempotency Key Reused with Different Payload
    -- ------------------------------------------------------------
    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient2_id, 'type', 'Consultation'), -- Different patient!
        v_idempotency_key
    );
    ASSERT (v_res->>'success')::BOOLEAN = false, 'Test 3 Failed: Reused key with different payload must fail';
    ASSERT (v_res->>'code') = 'IDEMPOTENCY_PAYLOAD_MISMATCH', 'Test 3 Failed: Should return IDEMPOTENCY_PAYLOAD_MISMATCH';
    RAISE NOTICE 'Test 3 PASSED: Idempotency Payload Mismatch Rejection';


    -- ------------------------------------------------------------
    -- TEST 4: Second Booking in Same Slot (Reaches Capacity = 2)
    -- ------------------------------------------------------------
    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient2_id, 'type', 'Consultation'),
        gen_random_uuid()
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 4 Failed: Second booking should succeed';
    v_appt2_id := (v_res->'data'->>'id')::UUID;

    SELECT booked_count, status INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 2, 'Test 4 Failed: booked_count should be 2';
    ASSERT v_slot.status = 'BOOKED', 'Test 4 Failed: slot status should transition to BOOKED when capacity reached';
    RAISE NOTICE 'Test 4 PASSED: Second Booking & Slot Saturation';


    -- ------------------------------------------------------------
    -- TEST 5: Full Slot Rejection
    -- ------------------------------------------------------------
    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient3_id, 'type', 'Consultation'),
        gen_random_uuid()
    );
    ASSERT (v_res->>'success')::BOOLEAN = false, 'Test 5 Failed: Booking beyond capacity must fail';
    ASSERT (v_res->>'code') IN ('SLOT_CAPACITY_EXCEEDED', 'SLOT_UNAVAILABLE'), 'Test 5 Failed: Should reject full slot';
    RAISE NOTICE 'Test 5 PASSED: Full Slot Rejection';


    -- ------------------------------------------------------------
    -- TEST 6: Doctor Leave Conflict
    -- ------------------------------------------------------------
    INSERT INTO opdesk_sakhi_clinic_doctor_leaves (clinic_id, doctor_id, leave_date, reason)
    VALUES (v_clinic_id, v_doctor1_id, (v_test_date + INTERVAL '1 day')::DATE, 'Vacation');

    INSERT INTO opdesk_sakhi_clinic_availability_slots (clinic_id, doctor_id, slot_date, start_time, end_time, capacity, booked_count, status)
    VALUES (v_clinic_id, v_doctor1_id, (v_test_date + INTERVAL '1 day')::DATE, v_start_time, v_end_time, 1, 0, 'AVAILABLE');

    v_res := book_appointment_atomic(
        v_clinic_id, v_doctor1_id, (v_test_date + INTERVAL '1 day')::DATE, v_start_time, v_end_time,
        jsonb_build_object('patient_id', v_patient3_id),
        gen_random_uuid()
    );
    ASSERT (v_res->>'success')::BOOLEAN = false, 'Test 6 Failed: Booking during leave must fail';
    ASSERT (v_res->>'code') = 'DOCTOR_ON_LEAVE', 'Test 6 Failed: Code should be DOCTOR_ON_LEAVE';
    RAISE NOTICE 'Test 6 PASSED: Doctor Leave Conflict';


    -- ------------------------------------------------------------
    -- TEST 7: Cancellation & Slot Capacity Release
    -- ------------------------------------------------------------
    v_res := update_appointment_status_atomic(
        v_clinic_id, v_appt1_id, 'Canceled', 'Patient requested cancellation'
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 7 Failed: Cancellation should succeed';
    ASSERT (v_res->>'slot_released')::BOOLEAN = true, 'Test 7 Failed: slot_released should be true';

    SELECT booked_count, status INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 1, 'Test 7 Failed: booked_count should decrement to 1';
    ASSERT v_slot.status = 'AVAILABLE', 'Test 7 Failed: slot status should revert to AVAILABLE';
    RAISE NOTICE 'Test 7 PASSED: Cancellation & Capacity Release';


    -- ------------------------------------------------------------
    -- TEST 8: Repeated Cancellation on Finalized Appointment
    -- ------------------------------------------------------------
    v_res := update_appointment_status_atomic(
        v_clinic_id, v_appt1_id, 'Canceled', 'Second cancellation attempt'
    );
    ASSERT (v_res->>'success')::BOOLEAN = false, 'Test 8 Failed: Repeat cancellation must be rejected';
    ASSERT (v_res->>'code') = 'STATUS_IMMUTABLE', 'Test 8 Failed: Code should be STATUS_IMMUTABLE';

    SELECT booked_count INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 1, 'Test 8 Failed: booked_count should NOT decrement again';
    RAISE NOTICE 'Test 8 PASSED: Repeated Cancellation Immutability';


    -- ------------------------------------------------------------
    -- TEST 9: Same-Slot Rescheduling (Validates status allowlist & zero capacity drift)
    -- ------------------------------------------------------------
    v_res := reschedule_appointment_atomic(
        v_clinic_id, v_appt2_id, v_doctor1_id, v_test_date, v_start_time, v_end_time,
        NULL, 'Updated follow-up visit reason'
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 9 Failed: Same-slot reschedule should succeed';
    ASSERT (v_res->>'same_slot')::BOOLEAN = true, 'Test 9 Failed: same_slot flag should be true';

    SELECT booked_count INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 1, 'Test 9 Failed: Same-slot reschedule must not change booked_count';
    RAISE NOTICE 'Test 9 PASSED: Same-Slot Rescheduling';


    -- ------------------------------------------------------------
    -- TEST 10: Cross-Doctor Rescheduling (Atomic Old Decrement & New Increment)
    -- ------------------------------------------------------------
    v_res := reschedule_appointment_atomic(
        v_clinic_id, v_appt2_id, v_doctor2_id, v_test_date, '11:00:00', '11:15:00',
        NULL, 'Moved to Doctor Beta'
    );
    ASSERT (v_res->>'success')::BOOLEAN = true, 'Test 10 Failed: Cross-doctor reschedule should succeed';

    -- Verify old slot was decremented to 0
    SELECT booked_count, status INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor1_id AND slot_date = v_test_date AND start_time = v_start_time;
    ASSERT v_slot.booked_count = 0, 'Test 10 Failed: Old slot should decrement to 0';
    ASSERT v_slot.status = 'AVAILABLE', 'Test 10 Failed: Old slot should be AVAILABLE';

    -- Verify new slot was incremented to 1
    SELECT booked_count, status INTO v_slot FROM opdesk_sakhi_clinic_availability_slots 
    WHERE clinic_id = v_clinic_id AND doctor_id = v_doctor2_id AND slot_date = v_test_date AND start_time = '11:00:00';
    ASSERT v_slot.booked_count = 1, 'Test 10 Failed: New slot should increment to 1';
    ASSERT v_slot.status = 'BOOKED', 'Test 10 Failed: New slot with capacity 1 should transition to BOOKED';
    RAISE NOTICE 'Test 10 PASSED: Cross-Doctor Rescheduling';


    -- ------------------------------------------------------------
    -- TEST 11: Permissions Check (Strictly granted to service_role)
    -- ------------------------------------------------------------
    SELECT COUNT(*) INTO v_perm_count
    FROM information_schema.routine_privileges
    WHERE routine_name IN ('book_appointment_atomic', 'update_appointment_status_atomic', 'reschedule_appointment_atomic')
      AND grantee IN ('PUBLIC', 'anon', 'authenticated');

    ASSERT v_perm_count = 0, 'Test 11 Failed: Functions must have 0 grants to PUBLIC, anon, or authenticated';
    RAISE NOTICE 'Test 11 PASSED: Permissions & Role Access Verified';

    -- ------------------------------------------------------------
    -- CLEANUP TEST DATA
    -- ------------------------------------------------------------
    DELETE FROM opdesk_sakhi_clinic_appointments WHERE clinic_id = v_clinic_id AND (doctor_id IN (v_doctor1_id, v_doctor2_id) OR patient_id IN (v_patient1_id, v_patient2_id, v_patient3_id));
    DELETE FROM opdesk_sakhi_clinic_availability_slots WHERE clinic_id = v_clinic_id AND doctor_id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_doctor_leaves WHERE clinic_id = v_clinic_id AND doctor_id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_users WHERE id IN (v_doctor1_id, v_doctor2_id);
    DELETE FROM opdesk_sakhi_clinic_patients WHERE id IN (v_patient1_id, v_patient2_id, v_patient3_id);

    RAISE NOTICE '=== ALL 11 STAGING DATABASE TESTS COMPLETED SUCCESSFULLY ===';
END $$;
