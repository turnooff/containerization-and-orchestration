-- Поиск аномалий роста спроса (не-AI шаг). Возвращает товары в формате входа skill.
-- Текущая неделя = последние 7 полных дней, прошлая = 7 дней до неё.
WITH s AS (
  SELECT p.sku, p.name, p.min_weekly_sales,
         (CURRENT_DATE - p.created_at) < 7 AS younger_than_week,
         COALESCE(SUM(oi.qty) FILTER (WHERE o.created_at >= CURRENT_DATE - 7
                                        AND o.created_at <  CURRENT_DATE), 0)     AS cur_qty,
         COALESCE(SUM(oi.qty) FILTER (WHERE o.created_at >= CURRENT_DATE - 14
                                        AND o.created_at <  CURRENT_DATE - 7), 0) AS prev_qty
  FROM products p
  LEFT JOIN order_items oi USING (sku)
  LEFT JOIN orders o ON o.id = oi.order_id
  GROUP BY p.sku, p.name, p.min_weekly_sales, p.created_at
)
SELECT s.sku, s.name, s.prev_qty, s.cur_qty,
       s.cur_qty - s.prev_qty                               AS growth,
       round(s.cur_qty::numeric / NULLIF(s.prev_qty, 0), 2) AS ratio,
       s.younger_than_week,
       f.expected_qty
FROM s
LEFT JOIN forecasts f ON f.sku = s.sku AND f.week_start = CURRENT_DATE - 7
WHERE s.cur_qty >= s.min_weekly_sales                                  -- порог объёма: отсекаем шум
  AND (
        -- обычный товар: рост больше чем в 1,5 раза к прошлой неделе
        (NOT s.younger_than_week AND s.prev_qty > 0 AND s.cur_qty > 1.5 * s.prev_qty)
        -- товар младше недели: прошлой недели нет, сравниваем с прогнозом
     OR (s.younger_than_week AND s.cur_qty > 1.5 * COALESCE(f.expected_qty, 0))
      )
  AND NOT EXISTS (                                                     -- дедупликация
        SELECT 1 FROM reported_anomalies r
        WHERE r.sku = s.sku AND r.reported_at > now() - interval '7 days'
      )
ORDER BY s.younger_than_week, ratio DESC;
