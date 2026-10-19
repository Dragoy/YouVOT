# YouVOT

Закадровый перевод видео в приложении YouTube для iOS — нейросетевая озвучка Яндекса прямо в плеере.
Нативный порт расширения [voice-over-translation](https://github.com/ilyhalight/voice-over-translation)
на Objective-C; протокол API взят из [vot.js](https://github.com/FOSWLY/vot.js).

> YouVOT не связан с Яндексом и Google. Перевод делают серверы Яндекса.

## Возможности

- **Закадровый перевод** любого видео на русский, английский или казахский. Озвучка синхронизирована
  с плеером: перемотка, пауза, скорость, реклама.
- **Мой язык.** Видео на вашем языке не переводятся. Язык речи определяется сам:
  по аудиодорожке, по автосубтитрам YouTube, по названию.
- **Не переводить автоматически** — языки, которые вы понимаете.
- **Автоперевод.** Включается сам, но только когда язык речи известен точно. Если выключить перевод
  вручную, это касается только текущего видео.
- **Тип озвучки:** обычная или **живые голоса** (только на русский). Для новых видео живым голосам
  нужен вход в аккаунт Яндекса; если они недоступны, включается обычная озвучка.
- **Shorts:** своя кнопка на экране Shorts и отдельный переключатель автоперевода для Shorts
  (по умолчанию выключен).
- **Громкость** оригинала (приглушается под перевод) и перевода.
- **Новые видео.** Если Яндекс ещё не переводил видео, YouVOT сам отправляет ему аудиодорожку,
  как это делает расширение.
- **Журнал перевода** в настройках: что определилось и что ответил Яндекс, если что-то пошло не так.
- Интерфейс на русском и английском.

## Управление

| Где | Нажатие | Долгое нажатие |
| --- | --- | --- |
| Кнопка перевода в плеере | открывает настройки; первая строка — «Перевод этого видео» | включает / выключает перевод |
| Кнопка перевода в Shorts (справа под верхней панелью) | открывает настройки | включает / выключает перевод |

Цвет кнопки: белая — перевод выключен, оранжевая — Яндекс готовит перевод, синяя — перевод играет.

Те же настройки есть в настройках YouTube в разделе «Закадровый перевод». Положение кнопки в плеере
(сверху или снизу) меняется в настройках YouTube → *Video Overlay*.

## Установка

YouVOT зависит от [YTVideoOverlay](https://github.com/PoomSmart/YTVideoOverlay). Его `.deb`
лежит в каждом [релизе](https://github.com/Dragoy/YouVOT/releases) рядом с YouVOT.

- **Без джейлбрейка (сайдлоад).** Возьмите из релиза rootless-пакеты (`*_iphoneos-arm64.deb`)
  YouVOT и YTVideoOverlay и встройте их в свой расшифрованный IPA YouTube с помощью
  [cyan](https://github.com/asdfzxcvbn/pyzule-rw), Feather или Esign. Например:
  `cyan -i YouTube.ipa -o YouTube+YouVOT.ipa -f com.ps.ytvideooverlay_*_iphoneos-arm64.deb com.dragoy.youvot_*_iphoneos-arm64.deb`.
  Если в вашей сборке YouTube YTVideoOverlay уже есть (он входит во многие сборки), достаточно YouVOT.
- **IPA через GitHub Actions.** Сделайте форк, откройте *Actions → Build IPA → Run workflow*
  и вставьте прямую ссылку на свой расшифрованный IPA YouTube. Готовый IPA появится
  в черновике релиза, который видите только вы. Расшифрованный IPA YouTube мы не распространяем.
- **Джейлбрейк.** Установите оба `.deb`: rootless — `iphoneos-arm64`, rootful — `iphoneos-arm`.

Нужен iOS 15 или новее.

## Сборка

Нужен [Theos](https://theos.dev) с заголовками
[YouTubeHeader](https://github.com/PoomSmart/YouTubeHeader) и [PSHeader](https://github.com/PoomSmart/PSHeader)
в `$THEOS/include`. YTVideoOverlay должен лежать рядом с папкой проекта:

```sh
git clone --depth=1 https://github.com/PoomSmart/YTVideoOverlay.git ../YTVideoOverlay
make clean package DEBUG=0 FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # rootless
make clean package DEBUG=0 FINALPACKAGE=1                                 # rootful
```

GitHub Actions собирает пакеты YouVOT и YTVideoOverlay на каждый push. Когда в `main` приходит новая версия из `control`, она публикуется в Releases (описание берётся из [CHANGELOG.md](CHANGELOG.md)).

## Как это работает

1. Сессия `api.browser.yandex.ru/session/create` и запрос `/video-translation/translate`
   для `https://youtu.be/<id>` с теми же подписями (`Vtrans-Signature`, `Sec-Vtrans-Sk`, `Sec-Vtrans-Token`),
   что и в расширении.
2. Язык видео определяется до запроса: аудиодорожка и автосубтитры из данных самого приложения,
   при необходимости — InnerTube, в крайнем случае название (на устройстве, NaturalLanguage).
3. Если Яндекс просит аудио (`AUDIO_REQUESTED`), YouVOT берёт самую лёгкую аудиодорожку
   (клиент InnerTube `ANDROID_VR`) и отправляет её частями по 5 МБ в `/video-translation/audio`.
4. Готовый mp3 играет через `AVPlayer` синхронно с плеером YouTube. Громкость оригинала понижается
   через `AVSampleBufferAudioRenderer` и `AVPlayer`.
5. Живые голоса: вход тем же OAuth, что у расширения; токен хранится в Keychain и отправляется
   только в запросах живых голосов.

## Ограничения

- Субтитры Яндекса пока не поддерживаются.
- Перевод синхронизируется по событиям времени плеера; если YouTube перестаёт их присылать
  в фоне, перевод встаёт на паузу.

## Благодарности

- [ilyhalight/voice-over-translation](https://github.com/ilyhalight/voice-over-translation) и
  [FOSWLY/vot.js](https://github.com/FOSWLY/vot.js) — расширение и протокол, на которых основан YouVOT.
- [PoomSmart](https://github.com/PoomSmart) — YTVideoOverlay, YouTubeHeader, PSHeader.

## Лицензия

[MIT](LICENSE)
