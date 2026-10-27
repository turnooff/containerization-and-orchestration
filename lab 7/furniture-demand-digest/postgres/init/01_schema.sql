-- Схема мок-БД мебельного магазина.
-- Все даты в seed считаются от CURRENT_DATE, поэтому при пересоздании контейнера
-- данные всегда описывают «последние две недели».

CREATE TABLE products (
    sku              text PRIMARY KEY,
    name             text NOT NULL,
    category         text NOT NULL,
    base_price       numeric(10,2) NOT NULL,
    created_at       date NOT NULL,           -- когда товар появился в каталоге
    min_weekly_sales int  NOT NULL            -- минимальный порог объёма для аномалии (свой у каждого товара)
);

CREATE TABLE customers (
    id    serial PRIMARY KEY,
    name  text NOT NULL,
    type  text NOT NULL CHECK (type IN ('person', 'company'))
);

CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id int  NOT NULL REFERENCES customers(id),
    created_at  timestamptz NOT NULL,
    city        text NOT NULL
);

CREATE TABLE order_items (
    order_id   int  NOT NULL REFERENCES orders(id),
    sku        text NOT NULL REFERENCES products(sku),
    qty        int  NOT NULL CHECK (qty > 0),
    unit_price numeric(10,2) NOT NULL
);

-- История цен: акции и скидки — отдельные периоды с promo_name.
CREATE TABLE price_history (
    sku        text NOT NULL REFERENCES products(sku),
    price      numeric(10,2) NOT NULL,
    valid_from date NOT NULL,
    valid_to   date,                          -- NULL = действует сейчас
    promo_name text
);

-- Результат работы сервиса прогнозирования спроса (сервис №3).
CREATE TABLE forecasts (
    sku          text NOT NULL REFERENCES products(sku),
    week_start   date NOT NULL,
    expected_qty int  NOT NULL,
    PRIMARY KEY (sku, week_start)
);

-- Дедупликация: по какому товару уже отправлен отчёт в текущем недельном окне.
CREATE TABLE reported_anomalies (
    sku         text NOT NULL REFERENCES products(sku),
    week_start  date NOT NULL,
    reported_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (sku, week_start)
);

CREATE INDEX ON orders (created_at);
CREATE INDEX ON order_items (sku);
