BEGIN;
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE TABLE IF NOT EXISTS raw.trudvsem_vacancy_ids (
    source_id uuid PRIMARY KEY,
    vacancy_id bigint GENERATED ALWAYS AS IDENTITY (START WITH -1 INCREMENT BY -1 MAXVALUE -1) UNIQUE
);
CREATE TABLE IF NOT EXISTS raw.vacancy_snapshots (
    vacancy_id bigint NOT NULL,
    observed_at timestamptz NOT NULL,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    PRIMARY KEY (vacancy_id, observed_at)
);
CREATE TABLE IF NOT EXISTS staging.vacancies (
    vacancy_id bigint PRIMARY KEY,
    observed_at timestamptz NOT NULL,
    published_at timestamptz NOT NULL,
    title text NOT NULL,
    city text,
    employer_id bigint,
    employer_name text,
    experience_code text,
    is_remote boolean,
    salary_from numeric CHECK (salary_from >= 0),
    salary_to numeric CHECK (salary_to >= 0),
    salary_currency text,
    salary_gross boolean,
    FOREIGN KEY (vacancy_id, observed_at) REFERENCES raw.vacancy_snapshots (vacancy_id, observed_at)
);
CREATE TABLE IF NOT EXISTS staging.vacancy_roles (
    vacancy_id bigint REFERENCES staging.vacancies ON DELETE CASCADE,
    role_id integer,
    role_name text NOT NULL,
    PRIMARY KEY (vacancy_id, role_id)
);
CREATE TABLE IF NOT EXISTS staging.vacancy_skills (
    vacancy_id bigint REFERENCES staging.vacancies ON DELETE CASCADE,
    skill_name text,
    PRIMARY KEY (vacancy_id, skill_name)
);
CREATE OR REPLACE VIEW mart.vacancies AS
SELECT v.*,
       date_trunc('week', published_at AT TIME ZONE 'Europe/Moscow')::date AS published_week,
       salary_from IS NOT NULL OR salary_to IS NOT NULL AS has_salary,
       CASE WHEN salary_currency = 'RUR' THEN
           COALESCE((salary_from + salary_to) / 2, salary_from, salary_to)
       END AS salary_estimate_rub
FROM staging.vacancies AS v;
CREATE OR REPLACE VIEW mart.vacancy_roles AS
SELECT v.*, r.role_id, r.role_name
FROM mart.vacancies AS v JOIN staging.vacancy_roles AS r USING (vacancy_id);
CREATE OR REPLACE VIEW mart.vacancy_skills AS
SELECT v.*, s.skill_name
FROM mart.vacancies AS v JOIN staging.vacancy_skills AS s USING (vacancy_id);
COMMIT;
