# Unica для Cursor

Скрипт для Windows, который подключает [Unica](https://github.com/IngvarConsulting/unica)
к редактору [Cursor](https://cursor.com).

Unica — набор инструментов и навыков для ИИ-агента, работающего с исходниками
1С:Предприятия: поиск по коду и метаданным, чтение и правка объектов, форм, ролей,
проверка изменений, выгрузка и загрузка информационной базы. Официально Unica
поставляется для Claude Code и Codex. Этот скрипт ставит её в Cursor.

## Зачем он нужен

- **Unica включается только там, где нужна.** Её ставят на компьютер один раз,
  а включают в каждом проекте 1С отдельно. В остальных проектах агент не видит
  ни навыков, ни инструментов Unica и не тратит на них контекст.
- **Unica работает в Cursor без доработок.** Скрипт исправляет несколько мест, где Cursor
  ведёт себя иначе, чем ждёт Unica: без этих правок инструменты отказывают или
  возвращают пустой ответ.
- **Форка нет.** Скрипт скачивает официальный пакет из
  [unica-marketplace](https://github.com/IngvarConsulting/unica-marketplace)
  и при каждом обновлении заново делает его пригодным для Cursor.
- **Обновление и откат одной командой.** Предыдущая версия остаётся на диске.

## Что нужно

Для скрипта:

- Windows 10 или 11, 64 бит. PowerShell 5.1 и .NET Framework 4 входят в Windows,
  ставить их не нужно.
- [Git for Windows](https://git-scm.com/download/win).
- [Cursor](https://cursor.com).
- Доступ к GitHub: оттуда скачиваются скрипт, пакет Unica и её компоненты.

Codex и Claude Code, которые Unica указывает среди требований, не нужны: их
заменяет Cursor. Node.js, Python и Java тоже не нужны: Unica скачивает свои
компоненты сама.

Для работы самой Unica нужна выгрузка конфигурации 1С в файлы. Чтобы работать
с информационной базой, нужна установленная платформа 1С. Подробности —
в [документации Unica](https://github.com/IngvarConsulting/unica-marketplace/blob/main/plugins/unica/README.md)
и в её [описании настроек проекта](https://github.com/IngvarConsulting/unica-marketplace/blob/main/plugins/unica/references/tooling/v8project.md).

## Быстрый старт

1. Скачайте репозиторий в постоянную папку. Не удаляйте её после установки:
   скрипт берёт из неё шаблоны.

   ```powershell
   git clone https://github.com/VictorMurashkin/unica-cursor.git "$env:USERPROFILE\unica-cursor"
   cd "$env:USERPROFILE\unica-cursor"
   ```

2. Установите Unica:

   ```powershell
   .\unica-cursor.cmd install
   ```

3. Включите её в проекте 1С:

   ```powershell
   .\unica-cursor.cmd enable -Path "D:\Projects\MyConfig"
   ```

4. В Cursor нажмите `Ctrl+Shift+P`, выполните **Developer: Reload Window** и
   откройте новый чат.

5. Проверьте: попросите агента «вызови unica.view». Он должен показать ваш
   проект и найденные наборы исходников.

Подключение к информационной базе нужно только для операций с базой. Как его
настроить, описано в [подробном руководстве](docs/usage.md#информационная-база-v8projectlocalyaml).

## Установка через ИИ-агента

Можно поручить установку агенту Cursor. Напишите ему в чате:

> Установи Unica для Cursor по инструкции
> https://github.com/VictorMurashkin/unica-cursor/blob/main/docs/agent-install.md
> и включи её в этом проекте.

Агент выполнит шаги из [docs/agent-install.md](docs/agent-install.md) и в конце
попросит вас перезагрузить окно.

## Основные команды

| Команда | Что делает |
| --- | --- |
| `install` | Ставит Unica на компьютер. |
| `enable -Path <проект>` | Включает Unica в проекте. |
| `disable -Path <проект>` | Выключает Unica в проекте. |
| `status` | Показывает, что установлено и включено. |
| `update` | Ставит новую версию Unica. |
| `rollback` | Возвращает предыдущую версию. |
| `uninstall` | Удаляет Unica с компьютера. |

Все параметры, режимы работы, список создаваемых файлов и решение проблем
описаны в [docs/usage.md](docs/usage.md).

## Ссылки

- [Подробное руководство](docs/usage.md)
- [Инструкция для ИИ-агента](docs/agent-install.md)
- [Unica](https://github.com/IngvarConsulting/unica)

## Лицензия

Скрипт передан в общественное достояние ([Unlicense](LICENSE)): его можно
использовать, менять и распространять без ограничений. На саму Unica это
не распространяется: у неё своя лицензия, LGPL-3.0.
