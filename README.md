# SimpClient

Неофициальный нативный iOS-клиент (SwiftUI, iOS 26 Liquid Glass) для XenForo-форума.

## Запуск
1. Создайте репозиторий на GitHub, загрузите содержимое этой папки (включая `.github`).
2. В `project.yml` поменяйте `PRODUCT_BUNDLE_IDENTIFIER`.
3. Actions → **Build unsigned IPA** → Run workflow → скачайте артефакт `.ipa`
   и подпишите/установите своим способом.
4. Либо добавьте secrets (см. комментарий в `build-signed.yml`) и запустите **Build signed IPA**.

## Если пусто или ошибка
Селекторы парсера лежат в `Sources/Models.swift` (enum `Parser`). Если вёрстка сайта
отличается от стандартного XenForo 2, правятся там.
