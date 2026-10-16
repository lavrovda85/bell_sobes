-- ============================================================
-- Задание 3. Баланс абонента через очередь
-- Поток: payment/expense -> balance_queue -> воркер -> subs_balance + balance_history
-- ============================================================

CREATE TABLE subs_balance (
  subs_id    NUMBER PRIMARY KEY,
  balance    NUMBER(18,2) DEFAULT 0 NOT NULL,
  updated_at TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
  -- Последний рубеж: даже если в коде баг, в минус БД не пустит.
  CONSTRAINT ck_balance_nonneg CHECK (balance >= 0)
);

CREATE TABLE subs_payment (
  pay_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subs_id    NUMBER NOT NULL REFERENCES subs_balance (subs_id),
  amount     NUMBER(18,2) NOT NULL CHECK (amount > 0),
  created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE subs_expense (
  exp_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subs_id    NUMBER NOT NULL REFERENCES subs_balance (subs_id),
  amount     NUMBER(18,2) NOT NULL CHECK (amount > 0),
  created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

-- Очередь. delta со знаком: платёж +, расход -.
-- UNIQUE (op_type, src_id) - защита от двойного начисления при ретраях продюсера.
CREATE TABLE balance_queue (
  queue_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subs_id       NUMBER NOT NULL REFERENCES subs_balance (subs_id),
  op_type       VARCHAR2(3) NOT NULL CHECK (op_type IN ('PAY','EXP')),
  src_id        NUMBER NOT NULL,
  delta         NUMBER(18,2) NOT NULL,
  status        VARCHAR2(8) DEFAULT 'NEW' NOT NULL CHECK (status IN ('NEW','DONE','REJECTED')),
  reject_reason VARCHAR2(200),
  created_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  processed_at  TIMESTAMP,
  CONSTRAINT uq_queue_src UNIQUE (op_type, src_id)
);
CREATE INDEX ix_queue_status_subs ON balance_queue (status, subs_id);

-- История - append-only: только вставки, никаких апдейтов. Остаток храним
-- в каждой строке, чтобы "баланс на момент X" не считался суммированием всего.
CREATE TABLE balance_history (
  hist_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subs_id       NUMBER NOT NULL REFERENCES subs_balance (subs_id),
  queue_id      NUMBER NOT NULL UNIQUE REFERENCES balance_queue (queue_id),
  op_type       VARCHAR2(3) NOT NULL,
  delta         NUMBER(18,2) NOT NULL,
  balance_after NUMBER(18,2) NOT NULL,
  created_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);
CREATE INDEX ix_hist_subs ON balance_history (subs_id, hist_id);

CREATE OR REPLACE PACKAGE pkg_balance AS
  -- Продюсеры. НЕ коммитят: транзакцией владеет вызывающий.
  PROCEDURE add_payment (p_subs_id NUMBER, p_amount NUMBER);
  PROCEDURE add_expense (p_subs_id NUMBER, p_amount NUMBER);

  -- Воркер. Можно запускать хоть в десяти сессиях - не подерутся.
  PROCEDURE process_queue;

  FUNCTION get_balance (p_subs_id NUMBER) RETURN NUMBER;
  FUNCTION get_history (p_subs_id NUMBER,
                        p_from    TIMESTAMP DEFAULT NULL,
                        p_to      TIMESTAMP DEFAULT NULL) RETURN SYS_REFCURSOR;
END pkg_balance;
/

CREATE OR REPLACE PACKAGE BODY pkg_balance AS

  PROCEDURE enqueue (p_subs_id NUMBER, p_op VARCHAR2, p_src_id NUMBER, p_delta NUMBER) IS
  BEGIN
    INSERT INTO balance_queue (subs_id, op_type, src_id, delta)
    VALUES (p_subs_id, p_op, p_src_id, p_delta);
  END;

  -- Платёж и событие в очередь - одной транзакцией: либо оба, либо ни одного.
  PROCEDURE add_payment (p_subs_id NUMBER, p_amount NUMBER) IS
    l_id NUMBER;
  BEGIN
    INSERT INTO subs_payment (subs_id, amount) VALUES (p_subs_id, p_amount)
    RETURNING pay_id INTO l_id;
    enqueue(p_subs_id, 'PAY', l_id, p_amount);
  END;

  PROCEDURE add_expense (p_subs_id NUMBER, p_amount NUMBER) IS
    l_id NUMBER;
  BEGIN
    INSERT INTO subs_expense (subs_id, amount) VALUES (p_subs_id, p_amount)
    RETURNING exp_id INTO l_id;
    enqueue(p_subs_id, 'EXP', l_id, -p_amount);
  END;

  PROCEDURE process_subscriber (p_subs_id NUMBER) IS
    TYPE t_item IS RECORD (
      queue_id      NUMBER,
      op_type       VARCHAR2(3),
      delta         NUMBER,
      status        VARCHAR2(8),
      reason        VARCHAR2(200),
      balance_after NUMBER
    );
    TYPE t_items IS TABLE OF t_item;
    TYPE t_idx   IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_items t_items;
    l_idx   t_idx;
    l_bal   NUMBER;
  BEGIN
    BEGIN
      SELECT balance INTO l_bal
        FROM subs_balance
       WHERE subs_id = p_subs_id
         FOR UPDATE SKIP LOCKED;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN;  
    END;

    SELECT queue_id, op_type, delta, 'DONE', NULL, NULL
      BULK COLLECT INTO l_items
      FROM balance_queue
     WHERE subs_id = p_subs_id AND status = 'NEW'
     ORDER BY queue_id;                 -- порядок поступления священен

    IF l_items.COUNT = 0 THEN RETURN; END IF;

    FOR i IN 1 .. l_items.COUNT LOOP
      IF l_bal + l_items(i).delta < 0 THEN
        l_items(i).status := 'REJECTED';
        l_items(i).reason := 'Insufficient funds';
      ELSE
        l_bal := l_bal + l_items(i).delta;
        l_items(i).balance_after := l_bal;
        l_idx(l_idx.COUNT + 1) := i;    -- запоминаем применённые
      END IF;
    END LOOP;

    -- В историю - только то, что реально изменило баланс. VALUES OF отфильтрует.
    FORALL j IN VALUES OF l_idx
      INSERT INTO balance_history (subs_id, queue_id, op_type, delta, balance_after)
      VALUES (p_subs_id, l_items(j).queue_id, l_items(j).op_type,
              l_items(j).delta, l_items(j).balance_after);

    FORALL i IN 1 .. l_items.COUNT
      UPDATE balance_queue
         SET status = l_items(i).status,
             reject_reason = l_items(i).reason,
             processed_at = SYSTIMESTAMP
       WHERE queue_id = l_items(i).queue_id;

    UPDATE subs_balance
       SET balance = l_bal, updated_at = SYSTIMESTAMP
     WHERE subs_id = p_subs_id;
  END process_subscriber;

  PROCEDURE process_queue IS
  BEGIN
    FOR r IN (SELECT DISTINCT subs_id FROM balance_queue WHERE status = 'NEW') LOOP
      BEGIN
        process_subscriber(r.subs_id);
        COMMIT;      
      EXCEPTION
        WHEN OTHERS THEN
          ROLLBACK;
          DBMS_OUTPUT.PUT_LINE('subs ' || r.subs_id || ' failed: ' || SQLERRM);
      END;
    END LOOP;
  END process_queue;

  FUNCTION get_balance (p_subs_id NUMBER) RETURN NUMBER IS
    l_bal NUMBER;
  BEGIN
    SELECT balance INTO l_bal FROM subs_balance WHERE subs_id = p_subs_id;
    RETURN l_bal;
  END;

  FUNCTION get_history (p_subs_id NUMBER,
                        p_from TIMESTAMP DEFAULT NULL,
                        p_to   TIMESTAMP DEFAULT NULL) RETURN SYS_REFCURSOR IS
    l_rc SYS_REFCURSOR;
  BEGIN
    OPEN l_rc FOR
      SELECT created_at, op_type, delta, balance_after
        FROM balance_history
       WHERE subs_id = p_subs_id
         AND (p_from IS NULL OR created_at >= p_from)
         AND (p_to   IS NULL OR created_at <  p_to)
       ORDER BY hist_id DESC;
    RETURN l_rc;
  END;

END pkg_balance;
/

-- Воркер по расписанию, раз в 10 секунд.
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_PROCESS_BALANCE_QUEUE',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pkg_balance.process_queue; END;',
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=10',
    enabled         => TRUE);
END;
/

-- Демо:
-- INSERT INTO subs_balance (subs_id) VALUES (1);
-- EXEC pkg_balance.add_payment(1, 500);  EXEC pkg_balance.add_expense(1, 120);
-- EXEC pkg_balance.add_expense(1, 9999); COMMIT;
-- EXEC pkg_balance.process_queue;
-- SELECT pkg_balance.get_balance(1) FROM dual;   -- 380, а расход на 9999 = REJECTED
