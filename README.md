# MountPetLink

A Legion 7.3.5 addon that extends the normal dress-up gesture (Ctrl+click, or whatever you've bound to the "Dressup" modified click) to mount-teaching items. Those items aren't equippable, so Blizzard's own dress-up handler silently ignores them — this opens the Mount Journal on the matching mount instead.

## Features

- **Ctrl+click a mount item** (bags, bank, vendor, trade, mail — anywhere `HandleModifiedItemClick` fires) to open the Mount Journal with the search box pre-filled and the first matching result auto-previewed, instead of nothing happening.
- **Three matching signals, unioned**: exact icon match, exact spell match (kept as a fallback in case it works on some items), and a Cyrillic-aware name-word-stem match (handles Russian declension, e.g. item "тундрового мамонта" vs mount "Тундровый мамонт"). An unambiguous single icon match is trusted outright; otherwise all three signals are combined into a candidate list.
- **Disambiguation picker** when more than one mount matches (recolors/variants sharing one icon) — a small scrollable window listing every candidate, white for mounts you've already collected, grey for the rest. Pick one to jump straight to it.
- **ElvUI skin support** for the picker window (border/background via ElvUI's `SetTemplate`, plus its scrollbar and close button), entirely inert if ElvUI isn't installed.
- **Doesn't close the vendor/trade window underneath it.** Opening the Mount Journal the normal way (`ToggleCollectionsJournal`) closes any open merchant or trade window as a side effect of Blizzard's own panel manager — this addon opens the journal a different way that avoids that, and always centers it on screen regardless of what else is open.

## Installation

Drop the `MountPetLink` folder into `Interface/AddOns/`. Optional: install ElvUI first if you want the picker window skinned to match.

## Commands

- `/mpldebug` — toggles debug logging (click handling, candidate matching, journal frame names) and prints a one-time snapshot of what's actually available on `C_MountJournal` on this client.
- `/mpltest <itemID>` — for a known item ID, dumps what each of the three matching signals (icon, spell, name-stem) independently sees, without needing an actual click.
- `/mplfind <substring>` — lists every mount whose name contains the given text, with its mount ID, icon, and spell ID — useful for checking a specific mount's real data directly.

## Known limitations

- **Mounts only** — battle pets aren't handled.
- `GetItemSpell` doesn't return a usable spell ID for mount-teaching items on this server (comes back as an empty string even for items already in your collection), so spell matching rarely contributes; icon and name-stem matching do the real work.
- Icon matching isn't exact — some mounts' item icons differ by a texture ID from the mount's own Journal icon even for visually identical recolors, which is why the picker and name-stem matching exist as a safety net.
- Name-stem matching is tuned for Russian declension; other locales aren't specifically handled.

---

# MountPetLink

Аддон для Legion 7.3.5, расширяющий стандартный жест примерки (Ctrl+ЛКМ, или что у вас назначено на модификатор "Dressup") на предметы, обучающие маунтам. Такие предметы не экипируются, поэтому стандартный обработчик примерки Blizzard их просто игнорирует — этот аддон вместо этого открывает Журнал маунтов на нужном маунте.

## Возможности

- **Ctrl+ЛКМ по предмету-маунту** (сумки, банк, вендор, трейд, почта — везде, где срабатывает `HandleModifiedItemClick`) открывает Журнал маунтов с готовым поиском и автоматическим превью первого найденного результата, вместо того чтобы ничего не происходило.
- **Три сигнала сопоставления, объединённые вместе**: точное совпадение по иконке, точное совпадение по заклинанию (оставлено на случай, если сработает для каких-то предметов), и сопоставление по словесным корням с учётом кириллицы (учитывает русские склонения, например предмет "тундрового мамонта" и маунт "Тундровый мамонт"). Однозначное совпадение по иконке принимается сразу; иначе все три сигнала объединяются в список кандидатов.
- **Окно выбора**, если совпало больше одного маунта (перекраски/варианты с одной иконкой) — небольшое прокручиваемое окно со списком кандидатов: белым — уже собранные маунты, серым — остальные. Клик по строке открывает выбранный маунт.
- **Поддержка скина ElvUI** для окна выбора (рамка/фон через `SetTemplate` ElvUI, плюс его полоса прокрутки и кнопка закрытия) — полностью неактивно, если ElvUI не установлен.
- **Не закрывает окно вендора/трейда под собой.** Открытие Журнала маунтов стандартным способом (`ToggleCollectionsJournal`) закрывает любое открытое окно продавца или трейда как побочный эффект собственного менеджера панелей Blizzard — этот аддон открывает журнал другим способом, который этого не делает, и всегда центрирует его на экране независимо от того, что ещё открыто.

## Установка

Положите папку `MountPetLink` в `Interface/AddOns/`. По желанию: установите ElvUI заранее, если хотите, чтобы окно выбора было оформлено в его стиле.

## Команды

- `/mpldebug` — включает/выключает отладочный вывод (обработка кликов, сопоставление кандидатов, имена фреймов журнала) и один раз печатает, что реально доступно в `C_MountJournal` на этом клиенте.
- `/mpltest <itemID>` — для известного ID предмета выводит, что видит каждый из трёх сигналов сопоставления (иконка, заклинание, словесный корень) по отдельности, без необходимости реального клика.
- `/mplfind <подстрока>` — выводит список всех маунтов, в названии которых встречается указанный текст, с их ID маунта, иконкой и ID заклинания — удобно, чтобы напрямую проверить реальные данные конкретного маунта.

## Известные ограничения

- **Только маунты** — боевые питомцы не обрабатываются.
- `GetItemSpell` не возвращает рабочий ID заклинания для предметов-маунтов на этом сервере (приходит пустая строка даже для уже собранных маунтов), так что сопоставление по заклинанию почти никогда не срабатывает — основную работу делают иконка и словесные корни.
- Сопоставление по иконке не идеально — у некоторых маунтов иконка предмета отличается на один texture ID от иконки самого маунта в журнале даже для визуально идентичных перекрасок, поэтому и существуют окно выбора и сопоставление по корням слов как подстраховка.
- Сопоставление по корням слов настроено на русские склонения; другие локали отдельно не обрабатываются.
