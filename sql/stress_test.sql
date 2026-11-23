-- Run after initializing raw, staging, mart, and the Trudvsem UUID mapping.
-- Expected: three INSERT 50000, three INSERT 0, 50000 rows, median 26500.5, and zero test rows after ROLLBACK.
-- PostgreSQL identity sequences can advance despite the rollback.
BEGIN;
CREATE TEMP TABLE stress_input ON COMMIT DROP AS
SELECT md5('it-dashboard-stress-2026:' || n)::uuid AS source_id,
       n, jsonb_build_object('test', true, 'n', n) AS payload
FROM generate_series(1, 50000) AS s(n);
    INSERT INTO raw.trudvsem_vacancy_ids (source_id)
    SELECT source_id FROM stress_input ON CONFLICT DO NOTHING;
    INSERT INTO raw.vacancy_snapshots (vacancy_id, observed_at, payload)
    SELECT m.vacancy_id, transaction_timestamp(), s.payload
    FROM stress_input s JOIN raw.trudvsem_vacancy_ids m USING (source_id)
    ON CONFLICT DO NOTHING;
    INSERT INTO staging.vacancies (vacancy_id, observed_at, published_at, title, salary_from, salary_to, salary_currency)
    SELECT m.vacancy_id, transaction_timestamp(), transaction_timestamp(),
           'Synthetic stress test', 1000+s.n, 2000+s.n, 'RUR'
    FROM stress_input s JOIN raw.trudvsem_vacancy_ids m USING (source_id)
    ON CONFLICT DO NOTHING;
    INSERT INTO raw.trudvsem_vacancy_ids (source_id)
    SELECT source_id FROM stress_input ON CONFLICT DO NOTHING;
    INSERT INTO raw.vacancy_snapshots (vacancy_id, observed_at, payload)
    SELECT m.vacancy_id, transaction_timestamp(), s.payload
    FROM stress_input s JOIN raw.trudvsem_vacancy_ids m USING (source_id)
    ON CONFLICT DO NOTHING;
    INSERT INTO staging.vacancies (vacancy_id, observed_at, published_at, title, salary_from, salary_to, salary_currency)
    SELECT m.vacancy_id, transaction_timestamp(), transaction_timestamp(),
           'Synthetic stress test', 1000+s.n, 2000+s.n, 'RUR'
    FROM stress_input s JOIN raw.trudvsem_vacancy_ids m USING (source_id)
    ON CONFLICT DO NOTHING;
SELECT count(*) AS vacancies, percentile_cont(0.5) WITHIN GROUP (ORDER BY v.salary_estimate_rub) AS median
FROM mart.vacancies v JOIN raw.trudvsem_vacancy_ids m USING (vacancy_id)
JOIN stress_input s USING (source_id);
ROLLBACK;
SELECT count(*) AS synthetic_rows_remaining FROM staging.vacancies WHERE title = 'Synthetic stress test';
