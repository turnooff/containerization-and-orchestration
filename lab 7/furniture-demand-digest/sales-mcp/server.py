"""sales-mcp — MCP-сервер с узкими инструментами для проверки гипотез о росте спроса.

Ходит в Postgres под read-only пользователем, наружу отдаёт MCP по Streamable HTTP
на :8000/mcp. Модель не пишет SQL — она только выбирает инструмент и передаёт SKU.
"""

import os
from datetime import date, datetime
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row
from mcp.server.fastmcp import FastMCP

DSN = (
    f"host={os.environ.get('DB_HOST', 'postgres')} "
    f"dbname={os.environ.get('DB_NAME', 'furniture')} "
    f"user={os.environ.get('DB_USER', 'mcp_reader')} "
    f"password={os.environ['DB_PASSWORD']}"
)

mcp = FastMCP("sales", host="0.0.0.0", port=8000)


def _query(sql: str, params: dict) -> list[dict]:
    with psycopg.connect(DSN, row_factory=dict_row) as conn:
        rows = conn.execute(sql, params).fetchall()
    return [{k: _jsonable(v) for k, v in r.items()} for r in rows]


def _jsonable(v):
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, (date, datetime)):
        return v.isoformat()
    return v


def _check_days(days: int) -> int:
    if not 1 <= days <= 90:
        raise ValueError("days должен быть от 1 до 90")
    return days


@mcp.tool()
def get_product_info(sku: str) -> dict:
    """Карточка товара: название, категория, базовая цена, дата появления в каталоге,
    возраст в днях и минимальный недельный порог продаж.
    Используй для проверки гипотезы «новинка»: товар моложе 45 дней считается новинкой.

    Args:
        sku: артикул товара, например "SOFA-OSLO".
    """
    rows = _query(
        """SELECT sku, name, category, base_price, created_at,
                  CURRENT_DATE - created_at AS age_days, min_weekly_sales
           FROM products WHERE sku = %(sku)s""",
        {"sku": sku},
    )
    if not rows:
        return {"error": f"товар {sku} не найден"}
    return rows[0]


@mcp.tool()
def get_large_orders(sku: str, days: int = 7, min_qty: int = 3) -> dict:
    """Крупные заказы товара за последние N дней: заказы, где в одном заказе
    не меньше min_qty штук. Возвращает дату, город, количество и покупателя
    (тип person — частное лицо, company — компания).
    Используй для проверки гипотезы «оптовая закупка». count = 0 — опта не было.

    Args:
        sku: артикул товара.
        days: за сколько последних полных дней смотреть (1–90), по умолчанию 7.
        min_qty: с какого количества в одном заказе считать заказ крупным, по умолчанию 3.
    """
    orders = _query(
        """SELECT o.created_at, o.city, oi.qty, c.name AS customer, c.type AS customer_type
           FROM order_items oi
           JOIN orders o ON o.id = oi.order_id
           JOIN customers c ON c.id = o.customer_id
           WHERE oi.sku = %(sku)s AND oi.qty >= %(min_qty)s
             AND o.created_at >= CURRENT_DATE - %(days)s AND o.created_at < CURRENT_DATE
           ORDER BY oi.qty DESC""",
        {"sku": sku, "days": _check_days(days), "min_qty": min_qty},
    )
    return {"sku": sku, "days": days, "min_qty": min_qty, "count": len(orders), "orders": orders}


@mcp.tool()
def get_price_history(sku: str, days: int = 30) -> dict:
    """История цен товара за последние N дней: периоды действия цены, название акции
    (promo_name, если была) и размер скидки в процентах от базовой цены.
    valid_to = null означает, что цена действует сейчас.
    Используй для проверки гипотезы «скидка». Обращай внимание на даты: старая акция
    не объясняет рост на текущей неделе.

    Args:
        sku: артикул товара.
        days: за сколько последних дней смотреть (1–90), по умолчанию 30.
    """
    prices = _query(
        """SELECT ph.price, ph.valid_from, ph.valid_to, ph.promo_name,
                  round(100 * (1 - ph.price / p.base_price), 1) AS discount_pct
           FROM price_history ph JOIN products p USING (sku)
           WHERE ph.sku = %(sku)s
             AND COALESCE(ph.valid_to, CURRENT_DATE) >= CURRENT_DATE - %(days)s
           ORDER BY ph.valid_from""",
        {"sku": sku, "days": _check_days(days)},
    )
    return {"sku": sku, "days": days, "periods": prices}


@mcp.tool()
def get_sales_by_city(sku: str, days: int = 7) -> dict:
    """Продажи товара по городам: штук за последние N дней и за N дней до этого.
    Показывает, был ли рост везде или сконцентрирован в одном городе.
    Используй для проверки гипотезы «реклама»: сопоставь город с ростом с городами
    рекламных кампаний из маркетингового календаря.

    Args:
        sku: артикул товара.
        days: длина периода в днях (1–45), по умолчанию 7.
    """
    if not 1 <= days <= 45:
        raise ValueError("days должен быть от 1 до 45")
    cities = _query(
        """SELECT o.city,
                  COALESCE(SUM(oi.qty) FILTER (WHERE o.created_at >= CURRENT_DATE - %(days)s), 0) AS current_qty,
                  COALESCE(SUM(oi.qty) FILTER (WHERE o.created_at <  CURRENT_DATE - %(days)s), 0) AS previous_qty
           FROM order_items oi JOIN orders o ON o.id = oi.order_id
           WHERE oi.sku = %(sku)s
             AND o.created_at >= CURRENT_DATE - 2 * %(days)s AND o.created_at < CURRENT_DATE
           GROUP BY o.city
           ORDER BY current_qty DESC""",
        {"sku": sku, "days": days},
    )
    return {"sku": sku, "days": days, "cities": cities}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
