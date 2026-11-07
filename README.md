<p align="center"><img src="docs/icon-1024.png" width="128" alt="Shuttle"></p>

<h1 align="center">Shuttle</h1>

<p align="center">Перетаскивание файлов между Mac и Android или Nintendo Switch по кабелю.</p>

![Shuttle](docs/screenshot-switch.png)

## Установка

1. Скачайте `Shuttle-<версия>.dmg` со страницы [Releases](../../releases).
2. Откройте DMG и перетащите Shuttle в «Программы».
3. При первом запуске откройте «Системные настройки → Конфиденциальность и безопасность» и нажмите «Всё равно открыть».

Требуется macOS 14 или новее, Apple Silicon или Intel.

## Возможности

- Две панели, Mac и устройство, перетаскивание в обе стороны и из Finder
- Все разделы устройства вкладками
- Таблица с сортировкой и раскрытием папок
- Очередь передач с прогрессом и отменой
- Тёмная и светлая темы

## Подключение

**Android:** подключите кабель и в уведомлении USB выберите «Передача файлов».

**Nintendo Switch:** запустите DBI, выберите «Run MTP responder» и подключите кабель.

Если устройство не находится, закройте «Захват изображений», «Фото» и Android File Transfer, затем переподключите кабель.

## Сборка из исходников

```bash
brew install xcodegen pkg-config
scripts/build-deps.sh
xcodegen generate
open Shuttle.xcodeproj
```

DMG: `scripts/make-dmg.sh`
