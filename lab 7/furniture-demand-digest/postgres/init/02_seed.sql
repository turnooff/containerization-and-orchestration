-- Мок-данные. «Текущая неделя» = последние 7 полных дней (CURRENT_DATE-7 .. CURRENT_DATE-1),
-- «прошлая неделя» = CURRENT_DATE-14 .. CURRENT_DATE-8.
--
-- Зашитые сценарии (что должен найти workflow):
--   SOFA-OSLO     рост ×2.7  — оптовый заказ кофейни на 12 шт.             → гипотеза «опт»
--   CHAIR-NORD    рост ×2.1  — скидка −30% последние 6 дней                → гипотеза «скидка»
--   TABLE-LUNA    рост ×2.0  — товару 18 дней, эффект новинки              → гипотеза «новинка»
--   BED-ARIA      рост ×2.7  — всплеск в Казани, там висит рекламный борд  → гипотеза «реклама»
--   WARDROBE-ALBA рост ×2.0  — без объяснения                              → «причина не найдена»
--   STOOL-MINI    рост ×2.0  — 2 → 4 шт., ниже порога объёма               → не аномалия (шум)
--   SHELF-KUBO    товару 3 дня, продано 12 при прогнозе 6                  → ветка «новинка младше недели»
--   остальные     стабильные продажи                                        → не аномалия

INSERT INTO products (sku, name, category, base_price, created_at, min_weekly_sales) VALUES
  ('SOFA-OSLO',     'Диван Осло',               'Диваны',   54990, CURRENT_DATE - 400, 5),
  ('CHAIR-NORD',    'Стул Норд',                'Стулья',    4990, CURRENT_DATE - 300, 10),
  ('TABLE-LUNA',    'Журнальный стол Луна',     'Столы',    12990, CURRENT_DATE - 18,  5),
  ('BED-ARIA',      'Кровать Ария 160×200',     'Кровати',  39990, CURRENT_DATE - 500, 5),
  ('WARDROBE-ALBA', 'Шкаф-купе Альба',          'Шкафы',    45990, CURRENT_DATE - 350, 5),
  ('STOOL-MINI',    'Табурет Мини',             'Стулья',    1490, CURRENT_DATE - 600, 10),
  ('SHELF-KUBO',    'Стеллаж Кубо',             'Хранение',  8990, CURRENT_DATE - 3,   5),
  ('ARMCHAIR-VEGA', 'Кресло Вега',              'Кресла',   21990, CURRENT_DATE - 250, 5),
  ('DESK-TERRA',    'Письменный стол Терра',    'Столы',    17990, CURRENT_DATE - 420, 5),
  ('DINING-RIGA',   'Обеденный стол Рига',      'Столы',    24990, CURRENT_DATE - 380, 5),
  ('MATTRESS-SOMN', 'Матрас Сомн 160×200',      'Матрасы',  19990, CURRENT_DATE - 700, 10);

-- Покупатели: 40 частных лиц и 3 компании.
INSERT INTO customers (name, type)
SELECT 'Покупатель #' || g, 'person' FROM generate_series(1, 40) g;
INSERT INTO customers (name, type) VALUES
  ('Кофейня «Зерно»',          'company'),   -- id 41
  ('ООО «Коворкинг Улей»',     'company'),   -- id 42
  ('Отель «Север»',            'company');   -- id 43

-- История цен: базовая цена у всех; у CHAIR-NORD — текущая скидка,
-- у SOFA-OSLO — старая акция двухмесячной давности (не должна объяснять текущий рост).
INSERT INTO price_history (sku, price, valid_from, valid_to, promo_name)
SELECT sku, base_price, GREATEST(created_at, CURRENT_DATE - 90), NULL, NULL
FROM products WHERE sku NOT IN ('CHAIR-NORD', 'SOFA-OSLO');

INSERT INTO price_history (sku, price, valid_from, valid_to, promo_name) VALUES
  ('CHAIR-NORD', 4990, CURRENT_DATE - 90, CURRENT_DATE - 7,  NULL),
  ('CHAIR-NORD', 3490, CURRENT_DATE - 6,  NULL,              'Осенняя распродажа −30%'),
  ('SOFA-OSLO', 54990, CURRENT_DATE - 90, CURRENT_DATE - 61, NULL),
  ('SOFA-OSLO', 46990, CURRENT_DATE - 60, CURRENT_DATE - 46, 'Летние диваны −15%'),
  ('SOFA-OSLO', 54990, CURRENT_DATE - 45, NULL,              NULL);

-- План розничных продаж: (sku, с какого дня назад, по какой день назад, штук в день, город или NULL = по кругу).
CREATE TEMP TABLE plan (sku text, d_from int, d_to int, per_day int, city text, price_factor numeric);
INSERT INTO plan VALUES
  ('SOFA-OSLO',     1, 14, 1, NULL,     1),
  ('CHAIR-NORD',    7, 14, 3, NULL,     1),
  ('CHAIR-NORD',    1,  6, 7, NULL,     0.7),
  ('TABLE-LUNA',    8, 14, 1, NULL,     1),
  ('TABLE-LUNA',    1,  7, 2, NULL,     1),
  ('BED-ARIA',      1, 14, 1, NULL,     1),
  ('BED-ARIA',      1,  6, 2, 'Казань', 1),
  ('WARDROBE-ALBA', 8, 14, 1, NULL,     1),
  ('WARDROBE-ALBA', 1,  7, 2, NULL,     1),
  ('STOOL-MINI',   11, 11, 1, NULL,     1),
  ('STOOL-MINI',   13, 13, 1, NULL,     1),
  ('STOOL-MINI',    2,  2, 1, NULL,     1),
  ('STOOL-MINI',    4,  6, 1, NULL,     1),
  ('SHELF-KUBO',    1,  3, 4, NULL,     1),
  ('ARMCHAIR-VEGA', 1, 14, 2, NULL,     1),
  ('DESK-TERRA',    1, 14, 1, NULL,     1),
  ('DINING-RIGA',   1, 14, 1, NULL,     1),
  ('MATTRESS-SOMN', 1, 14, 3, NULL,     1);

-- Разворачиваем план в отдельные заказы: один заказ = одна единица товара.
CREATE TEMP TABLE gen AS
SELECT row_number() OVER (ORDER BY p.sku, d, k) AS rn,
       p.sku, d, k, p.city, p.price_factor
FROM plan p
CROSS JOIN LATERAL generate_series(p.d_from, p.d_to) d
CROSS JOIN LATERAL generate_series(1, p.per_day) k;

INSERT INTO orders (id, customer_id, created_at, city)
SELECT rn,
       (rn % 40) + 1,
       (CURRENT_DATE - d) + interval '10 hours' + k * interval '47 minutes' + (rn % 30) * interval '1 minute',
       COALESCE(city, (ARRAY['Москва', 'Санкт-Петербург', 'Екатеринбург', 'Новосибирск'])[(rn % 4) + 1])
FROM gen;

INSERT INTO order_items (order_id, sku, qty, unit_price)
SELECT g.rn, g.sku, 1, round(pr.base_price * g.price_factor, 2)
FROM gen g JOIN products pr USING (sku);

SELECT setval('orders_id_seq', (SELECT max(id) FROM orders));

-- Оптовые и корпоративные заказы.
WITH o AS (
  INSERT INTO orders (customer_id, created_at, city)
  VALUES (41, (CURRENT_DATE - 3) + interval '12 hours', 'Москва')
  RETURNING id
)
INSERT INTO order_items (order_id, sku, qty, unit_price)
SELECT id, 'SOFA-OSLO', 12, 54990 FROM o;

-- Небольшой корпоративный заказ — не опт, но «шум» для агента.
WITH o AS (
  INSERT INTO orders (customer_id, created_at, city)
  VALUES (42, (CURRENT_DATE - 9) + interval '15 hours', 'Санкт-Петербург')
  RETURNING id
)
INSERT INTO order_items (order_id, sku, qty, unit_price)
SELECT id, 'ARMCHAIR-VEGA', 2, 21990 FROM o;

-- Прогнозы сервиса №3 на текущую неделю (примерно на уровне прошлой недели).
INSERT INTO forecasts (sku, week_start, expected_qty) VALUES
  ('SOFA-OSLO',     CURRENT_DATE - 7, 7),
  ('CHAIR-NORD',    CURRENT_DATE - 7, 22),
  ('TABLE-LUNA',    CURRENT_DATE - 7, 8),
  ('BED-ARIA',      CURRENT_DATE - 7, 7),
  ('WARDROBE-ALBA', CURRENT_DATE - 7, 7),
  ('STOOL-MINI',    CURRENT_DATE - 7, 2),
  ('SHELF-KUBO',    CURRENT_DATE - 7, 6),
  ('ARMCHAIR-VEGA', CURRENT_DATE - 7, 14),
  ('DESK-TERRA',    CURRENT_DATE - 7, 7),
  ('DINING-RIGA',   CURRENT_DATE - 7, 7),
  ('MATTRESS-SOMN', CURRENT_DATE - 7, 21);
