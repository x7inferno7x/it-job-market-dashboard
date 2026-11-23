"""Collect IT vacancies from the Work in Russia open-data API and load PostgreSQL."""

import argparse
from datetime import datetime, timezone
import json
import subprocess
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
from uuid import UUID

ENDPOINT = 'https://opendata.trudvsem.ru/api/v1/vacancies'
ROLE_TERMS = {
    1: ('Разработка', ('программист', 'разработчик')),
    2: ('Системное администрирование', ('системный администратор',)),
    3: ('Тестирование', ('тестировщик', 'инженер по тестированию')),
    4: ('Аналитика данных', ('аналитик данных',)),
}
PAGE_SIZE = 100


def request_page(term, offset):
    query = urlencode({'text': term, 'limit': PAGE_SIZE, 'offset': offset})
    request = Request(f'{ENDPOINT}?{query}', headers={'User-Agent': 'ITJobMarketPortfolio/1.0'})
    for attempt in range(4):
        try:
            with urlopen(request, timeout=45) as response:
                body = json.load(response)
            if str(body.get('status')) != '200':
                raise RuntimeError(f'API returned status {body.get("status")}')
            return [item['vacancy'] for item in body['results']['vacancies']]
        except HTTPError as error:
            if (error.code != 429 and error.code < 500) or attempt == 3:
                raise
        except (URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError('Retry limit reached')


def collect(max_pages):
    cards = {}
    for role_id, (role_name, terms) in ROLE_TERMS.items():
        for term in terms:
            previous_page_ids = set()
            for offset in range(max_pages):
                page = request_page(term, offset)
                page_ids = {str(UUID(str(card['id']))) for card in page}
                if not page_ids or page_ids == previous_page_ids:
                    break
                previous_page_ids = page_ids
                for card in page:
                    title = str(card.get('job-name') or '').casefold().replace('ё', 'е')
                    if not any(role_term in title for role_term in terms):
                        continue
                    source_id = str(UUID(str(card['id'])))
                    record = cards.setdefault(source_id, {'payload': card, 'roles': {}})
                    record['roles'][role_id] = role_name
                if len(page) < PAGE_SIZE:
                    break
                time.sleep(0.2)
    return list(cards.values())


LOAD = r"""
BEGIN;
CREATE TEMP TABLE incoming_json (line text) ON COMMIT DROP;
\copy incoming_json FROM STDIN
{data}
\.
CREATE TEMP TABLE incoming ON COMMIT DROP AS
SELECT doc -> 'payload' AS v, doc -> 'roles' AS roles,
       (doc #>> '{{payload,id}}')::uuid AS source_id
FROM (SELECT line::jsonb AS doc FROM incoming_json) AS records;
INSERT INTO raw.trudvsem_vacancy_ids (source_id)
SELECT source_id FROM incoming ON CONFLICT DO NOTHING;
INSERT INTO raw.vacancy_snapshots (vacancy_id, observed_at, payload)
SELECT m.vacancy_id, '{observed}'::timestamptz, i.v
FROM incoming i JOIN raw.trudvsem_vacancy_ids m USING (source_id)
ON CONFLICT DO NOTHING;
INSERT INTO staging.vacancies (
    vacancy_id, observed_at, published_at, title, city, employer_name, experience_code,
    is_remote, salary_from, salary_to, salary_currency
)
SELECT m.vacancy_id, '{observed}'::timestamptz,
       NULLIF(v ->> 'creation-date', '')::date::timestamp AT TIME ZONE 'Europe/Moscow',
       v ->> 'job-name', NULLIF(v #>> '{{addresses,address,0,location}}', ''),
       v #>> '{{company,name}}', NULLIF(v #>> '{{requirement,experience}}', ''),
       CASE WHEN v ->> 'schedule' ~* 'удален|удалён|дистанцион' THEN true END,
       CASE WHEN v ->> 'salary_min' ~ '^[0-9]+([.][0-9]+)?$' THEN NULLIF((v ->> 'salary_min')::numeric, 0) END,
       CASE WHEN v ->> 'salary_max' ~ '^[0-9]+([.][0-9]+)?$' THEN NULLIF((v ->> 'salary_max')::numeric, 0) END,
       'RUR'
FROM incoming i JOIN raw.trudvsem_vacancy_ids m USING (source_id)
WHERE NULLIF(v ->> 'creation-date', '') IS NOT NULL
ON CONFLICT (vacancy_id) DO UPDATE SET
    observed_at = EXCLUDED.observed_at, published_at = EXCLUDED.published_at,
    title = EXCLUDED.title, city = EXCLUDED.city, employer_name = EXCLUDED.employer_name,
    experience_code = EXCLUDED.experience_code, is_remote = EXCLUDED.is_remote,
    salary_from = EXCLUDED.salary_from, salary_to = EXCLUDED.salary_to,
    salary_currency = EXCLUDED.salary_currency
WHERE staging.vacancies.observed_at < EXCLUDED.observed_at;
DELETE FROM staging.vacancy_roles r USING incoming i, raw.trudvsem_vacancy_ids m, staging.vacancies v
WHERE i.source_id = m.source_id AND r.vacancy_id = m.vacancy_id
  AND v.vacancy_id = m.vacancy_id AND v.observed_at = '{observed}'::timestamptz;
INSERT INTO staging.vacancy_roles (vacancy_id, role_id, role_name)
SELECT m.vacancy_id, role.key::int, role.value
FROM incoming i JOIN raw.trudvsem_vacancy_ids m USING (source_id)
JOIN staging.vacancies v ON v.vacancy_id = m.vacancy_id
CROSS JOIN LATERAL jsonb_each_text(i.roles) AS role
WHERE v.observed_at = '{observed}'::timestamptz
ON CONFLICT DO NOTHING;
COMMIT;
"""


def load(cards):
    observed = datetime.now(timezone.utc).isoformat()
    # PostgreSQL COPY text format interprets backslashes. Escape each JSON line.
    data = '\n'.join(json.dumps(card, ensure_ascii=False).replace('\\', '\\\\') for card in cards)
    sql = LOAD.format(data=data, observed=observed)
    subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1'], input=sql, encoding='utf-8', check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-pages', type=int, default=30, help='page cap per search term')
    parser.add_argument('--dry-run', action='store_true', help='collect without writing to PostgreSQL')
    args = parser.parse_args()
    if args.max_pages < 1:
        parser.error('--max-pages must be positive')
    cards = collect(args.max_pages)
    if not cards:
        raise SystemExit('No matching IT vacancies returned')
    print(f'Collected {len(cards)} unique vacancies.', flush=True)
    if not args.dry_run:
        load(cards)


if __name__ == '__main__':
    main()
