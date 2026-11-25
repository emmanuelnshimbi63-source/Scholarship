 Scholarship Application Assessment
DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship;

(a) Tables and data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
('S001', 'Alice'), ('S002', 'Brian'), ('S003', 'Grace');

6 PENDING applications (qualifying, non-qualifying, boundary)
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 18, 3000, 70.00, '2026-11-01', 'PENDING'),   -- 1 boundary: all at limit, qualifies
(1, 25, 2500, 85.00, '2026-11-03', 'PENDING'),   -- 2 age 25, qualifies
(2, 24, 1500, 90.00, '2026-11-05', 'PENDING'),   -- 3 qualifies
(2, 26, 1000, 80.00, '2026-11-07', 'PENDING'),   -- 4 too old
(3, 20, 3001, 75.00, '2026-11-09', 'PENDING'),   -- 5 income just too high
(3, 22, 2000, 69.99, '2026-11-11', 'PENDING');   -- 6 mark just too low

(b) Function: eligibility
CREATE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs must not be NULL';
    END IF;
    IF p_age <= 0 OR p_income < 0 OR p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid age, income or mark';
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

SELECT fn_scholarship_eligible(18, 3000, 70);   -- true
SELECT fn_scholarship_eligible(26, 1000, 80);   -- false

(c) Procedure: assess one application
CREATE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_age INT; v_income NUMERIC; v_mark NUMERIC; v_status VARCHAR;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed', p_application_id;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

(d) Trigger: log real status changes
CREATE FUNCTION trg_decision_audit_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit_fn();

-- Test: assess application 1
CALL pr_assess_application(1);
SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit;                -- 1 row
-- Error tests: run each line alone
-- CALL pr_assess_application(1);            -- already assessed
-- CALL pr_assess_application(99);           -- unknown

(e) View: approved applicants (no income shown)
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index: status within a submitted_on range
-- Justification: the query filters status (equal) then submitted_on (range),
-- so one index on both columns finds the rows without reading the whole table.
CREATE INDEX idx_app_status_date ON applications (status, submitted_on);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
SET enable_seqscan = on;

(g) Scheduled job: assess all PENDING applications
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
CALL pr_assess_pending();                    -- rerun: nothing left to assess

SELECT * FROM applications ORDER BY application_id;   -- 1, 2, 3 APPROVED; 4, 5, 6 REJECTED
SELECT * FROM decision_audit;                         -- 6 rows, no duplicates
SELECT * FROM v_approved_applicants;                  -- 3 rows

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess_pending', '0 8 * * 1',
    $$CALL q10_scholarship.pr_assess_pending()$$);
SELECT * FROM cron.job;