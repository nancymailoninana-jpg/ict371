
DROP DATABASE IF EXISTS university_fees_db;
CREATE DATABASE university_fees_db;
USE university_fees_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE students (
    student_id     INT AUTO_INCREMENT PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_fee_due CHECK (fee_due >= 0)
) ENGINE=InnoDB;

CREATE TABLE payments (
    payment_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id INT           NOT NULL,
    amount     DECIMAL(10,2) NOT NULL,
    paid_on    DATE          NOT NULL,
    CONSTRAINT fk_pay_student FOREIGN KEY (student_id)
        REFERENCES students (student_id),
    CONSTRAINT chk_pay_amount CHECK (amount > 0)
) ENGINE=InnoDB;

CREATE TABLE payment_audit (
    audit_id   INT AUTO_INCREMENT PRIMARY KEY,
    payment_id INT           NOT NULL,
    student_id INT           NOT NULL,
    amount     DECIMAL(10,2) NOT NULL,
    logged_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_payment FOREIGN KEY (payment_id)
        REFERENCES payments (payment_id),
    CONSTRAINT fk_audit_student FOREIGN KEY (student_id)
        REFERENCES students (student_id)
) ENGINE=InnoDB;

CREATE TABLE daily_collections (
    collection_date DATE          PRIMARY KEY,
    payment_count   INT           NOT NULL DEFAULT 0,
    total_amount    DECIMAL(12,2) NOT NULL DEFAULT 0.00
) ENGINE=InnoDB;

-- Three students with different balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S2026001', 'Amina Khan',  5000.00),   -- will have a partial balance
    ('S2026002', 'Brian Otieno', 3000.00),  -- will be fully settled
    ('S2026003', 'Chen Li',      4000.00);  -- no payments yet

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_fee  DECIMAL(10,2);
    DECLARE v_paid DECIMAL(12,2);

    SET v_fee = (SELECT fee_due FROM students WHERE student_id = p_student_id);

    IF v_fee IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;

    -- COALESCE: a student with no payments has SUM = NULL, so use 0
    SET v_paid = (SELECT COALESCE(SUM(amount), 0)
                    FROM payments WHERE student_id = p_student_id);

    RETURN v_fee - v_paid;
END$$

-- =====================================================================
-- (c) PROCEDURE  (does NOT touch payment_audit; the trigger does)
-- =====================================================================
CREATE PROCEDURE pr_receive_payment(
    IN p_student_id INT,
    IN p_amount     DECIMAL(10,2),
    IN p_paid_on    DATE
)
BEGIN
    DECLARE v_fee     DECIMAL(10,2);
    DECLARE v_balance DECIMAL(12,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero';
    END IF;
    IF p_paid_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment date is required';
    END IF;

    START TRANSACTION;

    -- Lock the student row so concurrent payments cannot overpay together
    SELECT fee_due INTO v_fee
      FROM students
     WHERE student_id = p_student_id
       FOR UPDATE;

    IF v_fee IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;

    SET v_balance = fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds outstanding balance';
    END IF;

    -- fee_due is never modified; the balance is derived from payments
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGER
-- =====================================================================
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent)
-- =====================================================================
CREATE PROCEDURE pr_refresh_collections(IN p_day DATE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Day is required';
    END IF;

    START TRANSACTION;

    DELETE FROM daily_collections WHERE collection_date = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day,
           COUNT(*),
           COALESCE(SUM(amount), 0)
      FROM payments
     WHERE paid_on = p_day;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW - only students who still owe money
-- =====================================================================
CREATE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
  FROM students s
  LEFT JOIN payments p ON p.student_id = s.student_id
 GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- =====================================================================
-- (f) INDEX
-- Equality column first (student_id), range column second (paid_on):
-- one student's payments are found directly and already sorted by date,
-- so the date range is a short contiguous slice of the index.
-- It also replaces the single-column FK index on student_id.
-- =====================================================================
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

-- =====================================================================
-- (a) SEED PAYMENTS - six payments through the procedure
-- =====================================================================
CALL pr_receive_payment(1, 1000.00, '2026-11-20');
CALL pr_receive_payment(1, 1500.00, '2026-11-22');
CALL pr_receive_payment(2, 1000.00, '2026-11-22');
CALL pr_receive_payment(2, 1000.00, '2026-11-23');
CALL pr_receive_payment(1,  500.00, '2026-11-23');
CALL pr_receive_payment(2, 1000.00, '2026-11-24');   -- Brian now fully settled

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
-- (b)
SELECT fn_fee_balance(1) AS amina_balance,      -- 2000.00
       fn_fee_balance(2) AS brian_balance,      -- 0.00
       fn_fee_balance(3) AS chen_full_fee;      -- 4000.00 (no payments)
-- SELECT fn_fee_balance(99);                   -- error: Unknown student

-- (c) invalid payments (run one at a time; each errors, nothing changes)
-- CALL pr_receive_payment(1, NULL,   '2026-11-24');   -- NULL amount
-- CALL pr_receive_payment(1, 0,      '2026-11-24');   -- zero
-- CALL pr_receive_payment(1, -50,    '2026-11-24');   -- negative
-- CALL pr_receive_payment(1, 2500,   '2026-11-24');   -- exceeds 2000 balance
-- CALL pr_receive_payment(99, 100,   '2026-11-24');   -- unknown student
SELECT student_id, fee_due FROM students;              -- fee_due unchanged

-- (d) one audit row per payment, created by the trigger
SELECT * FROM payment_audit ORDER BY audit_id;

-- (e) Brian (settled) is excluded; Amina and Chen appear
SELECT * FROM v_fee_balances;

-- (f) plan for the matching query
ANALYZE TABLE payments;
EXPLAIN
SELECT payment_id, amount, paid_on
  FROM payments
 WHERE student_id = 1
   AND paid_on BETWEEN '2026-11-20' AND '2026-11-23';

-- (g) rerun: the row is replaced, never duplicated
CALL pr_refresh_collections('2026-11-22');
CALL pr_refresh_collections('2026-11-22');
CALL pr_refresh_collections('2026-11-23');
SELECT * FROM daily_collections ORDER BY collection_date;

-- Scheduled job: every day at 01:00 for the previous day
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_collections_daily
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
DO CALL pr_refresh_collections(CURRENT_DATE - INTERVAL 1 DAY);

SHOW EVENTS FROM university_fees_db;