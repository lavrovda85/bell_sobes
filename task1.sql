-- ============================================================
-- Задание 1. Сумма первых 10 живых платежей на абонента
-- ============================================================
-- n в test_data - из секвенса. Если таблица уже не пустая - стартуем с MAX(n)+1.
CREATE SEQUENCE test_data_seq START WITH 1 INCREMENT BY 1 NOCACHE;

DECLARE
  TYPE t_rec IS RECORD (
    clnt_id     test_pay.clnt_id%TYPE,
    subs_id     test_pay.subs_id%TYPE,
    all_pay_sum NUMBER
  );
  TYPE t_tab IS TABLE OF t_rec;
  TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  l_tab t_tab;
  l_idx t_idx;
BEGIN
  SELECT clnt_id, subs_id, SUM(pay_sum)
    BULK COLLECT INTO l_tab
    FROM (SELECT clnt_id, subs_id, pay_sum,
                 ROW_NUMBER() OVER (PARTITION BY subs_id
                                    ORDER BY pay_date, ROWID) AS rn
            FROM test_pay
           WHERE del_date IS NULL)
   WHERE rn <= 10
   GROUP BY clnt_id, subs_id
   ORDER BY clnt_id, subs_id;    
  FOR k IN 1 .. TRUNC(l_tab.COUNT / 3) LOOP
    l_idx(k) := k * 3;
  END LOOP;
  FORALL j IN VALUES OF l_idx
    INSERT INTO test_data (n, clnt_id, subs_id, all_pay_sum)
    VALUES (test_data_seq.NEXTVAL, l_tab(j).clnt_id, l_tab(j).subs_id, l_tab(j).all_pay_sum);

  COMMIT;
END;
/


