-- ICT371 Advanced Databases | Question 4
-- Clinic Appointment Scheduling
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q04.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The partial unique index enforces the slot rule even when two transactions book the
-- same slot concurrently. Run the sample inserts after installing the trigger in part
-- (d).
CREATE SCHEMA ict371_q04;
SET search_path = ict371_q04, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE patients (
    patient_id integer PRIMARY KEY,
    full_name text NOT NULL
);

CREATE TABLE doctors (
    doctor_id integer PRIMARY KEY,
    full_name text NOT NULL
);

CREATE TABLE appointments (
    appointment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id integer NOT NULL REFERENCES patients,
    doctor_id integer NOT NULL REFERENCES doctors,
    appointment_day date NOT NULL CHECK (isfinite(appointment_day)),
    slot_time time NOT NULL CHECK (slot_time IN (
        TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00'
    )),
    status text NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE UNIQUE INDEX uq_appointments_active_slot
ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date date PRIMARY KEY,
    booked_count bigint NOT NULL CHECK (booked_count >= 0),
    attended_count bigint NOT NULL CHECK (attended_count >= 0),
    cancelled_count bigint NOT NULL CHECK (cancelled_count >= 0)
);

INSERT INTO patients VALUES
    (1, 'Ruth Banda'), (2, 'David Phiri'), (3, 'Mary Zulu');

INSERT INTO doctors VALUES
    (1, 'Dr Tembo'), (2, 'Dr Chanda'), (3, 'Dr Mwale');

-- (b) Function
-- COUNT returns zero for a known doctor with no matching appointments.
CREATE FUNCTION fn_daily_load(p_doctor_id integer, p_day date)
RETURNS bigint LANGUAGE plpgsql SET search_path = ict371_q04, pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor ID: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR NOT isfinite(p_day) THEN
        RAISE EXCEPTION 'A valid appointment date is required';
    END IF;

    RETURN (
        SELECT COUNT(*) FROM appointments
        WHERE doctor_id = p_doctor_id AND appointment_day = p_day
          AND status <> 'CANCELLED'
    );
END;
$$;

-- (c) Procedure
-- The procedure checks both IDs, checks today-or-later scheduling and validates the
-- slot before inserting a BOOKED row.
CREATE PROCEDURE pr_book_appointment(
    p_patient_id integer, p_doctor_id integer, p_day date, p_slot time
)
LANGUAGE plpgsql SET search_path = ict371_q04, pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient ID: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor ID: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR NOT isfinite(p_day) OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date must be today or later';
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (
        TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;

    INSERT INTO appointments
        (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger
-- On an update, the trigger excludes the row’s existing ID from the clash check. A
-- cancelled record may share a slot with a live appointment.
CREATE FUNCTION fn_check_appointment_slot()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q04, pg_catalog AS $$
DECLARE
    v_existing_id bigint;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_existing_id := OLD.appointment_id;
    END IF;
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments AS a
        WHERE a.doctor_id = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time = NEW.slot_time
          AND a.status <> 'CANCELLED'
          AND (v_existing_id IS NULL OR a.appointment_id <> v_existing_id)
    ) THEN
        RAISE EXCEPTION 'That doctor already has an appointment in this slot';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_appointment_slot
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION fn_check_appointment_slot();

-- (a) Deferred seed data, loaded after the routines and trigger
INSERT INTO appointments
    (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES
    (1, 1, CURRENT_DATE,     TIME '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     TIME '09:00', 'CANCELLED'),
    (2, 1, CURRENT_DATE,     TIME '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     TIME '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, TIME '11:00', 'ATTENDED'),
    (3, 3, CURRENT_DATE - 1, TIME '12:00', 'CANCELLED');

-- (e) View
-- The view projects only the two names and the slot. It returns three booked
-- appointments on the seed date.
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name,
       a.slot_time
FROM appointments AS a
JOIN patients AS p USING (patient_id)
JOIN doctors AS d USING (doctor_id)
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- (f) Index and execution plan
-- The non-unique index covers all statuses and supports searches by date alone or with
-- the doctor ID.
CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);

EXPLAIN (COSTS OFF)
SELECT appointment_id, slot_time, status FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;

-- Plan observed on the seed dataset:
-- Seq Scan on appointments
--   Filter: ((doctor_id = 1) AND (appointment_day = CURRENT_DATE))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_appointments_day_doctor on appointments
--   Index Cond: ((appointment_day = CURRENT_DATE) AND (doctor_id = 1))

-- (g) Scheduled job
-- FILTER counts each status separately. The job refreshes the previous day at 01:00 and
-- replaces all three counts on a rerun.
CREATE PROCEDURE pr_refresh_clinic_summary(p_day date)
LANGUAGE plpgsql SET search_path = ict371_q04, pg_catalog AS $$
BEGIN
    IF p_day IS NULL OR NOT isfinite(p_day) THEN
        RAISE EXCEPTION 'A valid summary date is required';
    END IF;

    INSERT INTO clinic_summary
        (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day, COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary;
ROLLBACK;

-- For the day before the seed date, the summary shows zero booked, one attended and one
-- cancelled appointment.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q04',
    '0 1 * * *',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q04.pr_refresh_clinic_summary((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);
    $job$
);
*/
