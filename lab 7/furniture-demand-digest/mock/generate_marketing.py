"""Генерирует маркетинговый календарь с датами относительно сегодняшнего дня,
чтобы он совпадал с мок-данными в Postgres (там всё тоже от CURRENT_DATE).

Запуск: python generate_marketing.py <папка-назначения>
"""

import sys
from datetime import date, timedelta
from pathlib import Path

today = date.today()


def d(days_ago: int) -> str:
    return (today - timedelta(days=days_ago)).strftime("%d.%m.%Y")


CAMPAIGNS = f"""# Маркетинговый календарь — активные и недавние кампании

Ведёт: отдел маркетинга. Обновлено: {d(0)}.

| Период | Товар (SKU) | Канал | Где | Комментарий |
|---|---|---|---|---|
| {d(6)} – {d(-8)} | BED-ARIA | Наружная реклама, билборд 6×3 | Казань, ул. Баумана, у ТЦ «Кольцо» | «Кровать Ария — спите как дома» |
| {d(10)} – {d(4)} | MATTRESS-SOMN | Листовки, 5 000 шт. | Санкт-Петербург, ст. м. «Московская» и «Звёздная» | раздавали промоутеры по будням |
| {d(40)} – {d(26)} | SOFA-OSLO | Таргет в соцсетях | вся Россия | кампания завершена |
| {d(-5)} – {d(-19)} | DINING-RIGA | Наружная реклама, ситиборды | Екатеринбург, центр | запланирована, ещё не стартовала |
"""

NOTES = f"""# Заметки маркетинга

- {d(12)}: согласовали билборд для кровати Ария в Казани, монтаж через неделю.
- {d(9)}: листовки по матрасам Сомн — отклик слабый, продлевать не будем.
- {d(3)}: идея на зиму — подборка «уютная гостиная» (кресла + журнальные столы).
"""

out = Path(sys.argv[1] if len(sys.argv) > 1 else "marketing")
out.mkdir(parents=True, exist_ok=True)
(out / "campaigns.md").write_text(CAMPAIGNS, encoding="utf-8")
(out / "notes.md").write_text(NOTES, encoding="utf-8")
print(f"marketing calendar written to {out}/ (today = {today})")
