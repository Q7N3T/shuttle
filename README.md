<p align="center"><img src="docs/icon-1024.png" width="128" alt="Shuttle"></p>

<h1 align="center">Shuttle</h1>

<p align="center">Перетаскивание файлов между Mac и Android или Nintendo Switch по кабелю.</p>

![Shuttle](docs/screenshot-switch.png)

## Установка

**[Скачать последнюю версию](https://github.com/Q7N3T/shuttle/releases/latest)** · [Сайт](https://q7n3t.github.io/shuttle/) · macOS 14+, Apple Silicon и Intel

1. Откройте DMG.
2. Перетащите Shuttle в «Программы».
3. Запустите Shuttle.

> Если macOS не даёт открыть приложение, зайдите в
> **Настройки → Конфиденциальность и безопасность**
> и нажмите **«Всё равно открыть»**. Это нужно один раз.

## Возможности

- Две панели, Mac и устройство, перетаскивание в обе стороны и из Finder
- Все разделы устройства вкладками
- Таблица с сортировкой и раскрытием папок
- Очередь передач с прогрессом и отменой
- Тёмная и светлая темы
- Автообновления: новая версия придёт сама

[История версий](CHANGELOG.md) · [все сборки](https://github.com/Q7N3T/shuttle/releases)

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

Выпуск новой версии: поднимите версию в `project.yml`, допишите `CHANGELOG.md` и запустите `scripts/release.sh`.
