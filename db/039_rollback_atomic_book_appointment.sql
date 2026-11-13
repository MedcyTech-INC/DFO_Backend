-- ============================================================
-- Migration 039 Rollback: Revert Atomic Booking, Status & Rescheduling RPCs
--
-- Safe Rollback Scope:
-- 1. Drops newly created atomic functions with RESTRICT.
-- 2. Drops the clinic-scoped idempotency unique partial index.
-- 3. Preserves the idempotency_key column to avoid data loss.
--
-- OPERATIONAL LIMITATIONS & WARNINGS:
-- 1. Function Dependency: Dropping atomic functions (book_appointment_atomic,
--    update_appointment_status_atomic, reschedule_appointment_atomic) breaks
--    appointment creation, status updates, and rescheduling until the previous
--    NestJS non-RPC application code is deployed.
-- 2. Concurrency Vulnerability: Dropping the unique index idx_appointments_clinic_idempotency_key
--    removes database-level duplicate enforcement and concurrent race safety.
-- 3. Column Data Preservation: The idempotency_key column is deliberately retained
--    (not dropped) on opdesk_sakhi_clinic_appointments so historical idempotency audit
--    data is not lost.
-- 4. State Immutability: Rolling back functions and indexes does NOT revert or alter
--    previously booked appointments, changed statuses, or slot capacities committed
--    while Migration 039 was active.
-- ============================================================

-- Step 1: Drop atomic functions safely with RESTRICT
DROP FUNCTION IF EXISTS reschedule_appointment_atomic(UUID, UUID, UUID, DATE, TIME, TIME, UUID, TEXT) RESTRICT;
DROP FUNCTION IF EXISTS update_appointment_status_atomic(UUID, UUID, VARCHAR, TEXT, TIMESTAMPTZ, VARCHAR) RESTRICT;
DROP FUNCTION IF EXISTS book_appointment_atomic(UUID, UUID, DATE, TIME, TIME, JSONB, UUID) RESTRICT;

-- Step 2: Drop the partial unique index
DROP INDEX IF EXISTS idx_appointments_clinic_idempotency_key;
DROP INDEX IF EXISTS idx_appointments_idempotency_key;

-- Step 3: Column preservation (optional column removal if returning to clean state)
-- ALTER TABLE IF EXISTS opdesk_sakhi_clinic_appointments DROP COLUMN IF EXISTS idempotency_key;
