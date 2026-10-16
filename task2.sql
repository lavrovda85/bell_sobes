-- ============================================================
-- Задание 2. Цикл, коммит каждые 5 шагов, ошибочные шаги - в корзину
-- ============================================================

DECLARE
  c_steps  CONSTANT PLS_INTEGER := 23;
  c_commit CONSTANT PLS_INTEGER := 5;
  l_err    VARCHAR2(4000);
BEGIN
  FOR i IN 1 .. c_steps LOOP
    SAVEPOINT sp_step;
    BEGIN
      UPDATE test SET n = n - 1 WHERE n = i;
      INSERT INTO test_log (n) VALUES (i);
    EXCEPTION
      WHEN OTHERS THEN
        l_err := SQLERRM;                    
        ROLLBACK TO SAVEPOINT sp_step;       
        DBMS_OUTPUT.PUT_LINE('step ' || i || ' rolled back: ' || l_err);
    END;
    IF MOD(i, c_commit) = 0 THEN
      COMMIT;
    END IF;
  END LOOP;

  COMMIT; 
END;
/