-- 1. Coverage of the collected snapshot by source publication week.
SELECT published_week, count(*) AS vacancies FROM mart.vacancies GROUP BY 1 ORDER BY 1;

-- 2. Weekly change in observed publications, not in the market stock of open jobs.
WITH weekly AS (SELECT published_week, count(*) AS vacancies FROM mart.vacancies GROUP BY 1)
SELECT *, vacancies - lag(vacancies) OVER (ORDER BY published_week) AS change
FROM weekly ORDER BY published_week;

-- 3. Role demand. Multi-role vacancies are counted separately in each role.
SELECT role_name, count(*) AS vacancies FROM mart.vacancy_roles GROUP BY 1 ORDER BY 2 DESC;

-- 4. Estimated salary median and sample size by role.
SELECT role_name, count(salary_estimate_rub) AS salary_sample,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY salary_estimate_rub) AS median_rub
FROM mart.vacancy_roles GROUP BY 1 ORDER BY 2 DESC;

-- 5. Estimated salary median by reported experience value.
SELECT experience_code, count(salary_estimate_rub) AS salary_sample,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY salary_estimate_rub) AS median_rub
FROM mart.vacancies WHERE experience_code IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

-- 6. Compare salary disclosure between roles.
SELECT role_name, count(*) AS vacancies,
       round(100.0 * count(*) FILTER (WHERE has_salary) / count(*), 1) AS salary_coverage_pct
FROM mart.vacancy_roles GROUP BY 1 ORDER BY 3 DESC;

-- 7. Compare recorded locations and show disclosed salary counts for context.
SELECT city AS source_location, count(*) AS vacancies, count(salary_estimate_rub) AS salary_sample,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY salary_estimate_rub) AS median_rub
FROM mart.vacancies WHERE city IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

-- 8. Explicit remote mentions are a lower bound. Unknown formats remain visible.
SELECT role_name, count(*) FILTER (WHERE is_remote) AS remote_mentions,
       count(*) FILTER (WHERE is_remote IS NULL) AS unknown_format, count(*) AS vacancies
FROM mart.vacancy_roles GROUP BY 1 ORDER BY 2 DESC;

-- 9. Employers with the most vacancies in the sample, including ties.
WITH employers AS (
    SELECT employer_name, count(*) AS vacancies FROM mart.vacancies
    WHERE employer_name IS NOT NULL GROUP BY 1
), ranked AS (
    SELECT *, dense_rank() OVER (ORDER BY vacancies DESC) AS employer_rank FROM employers
)
SELECT * FROM ranked WHERE employer_rank <= 10 ORDER BY employer_rank, employer_name;

-- 10. Detect gaps in data needed for the experience, location, and format analyses.
SELECT count(*) AS total, count(experience_code) AS known_experience,
       count(city) AS known_location, count(is_remote) AS known_format,
       count(salary_estimate_rub) AS usable_salary
FROM mart.vacancies;
