# FocusBreak

FocusBreak, uzun sure ekrana bakan yazilimcilar ve ofis calisanlari icin arastirma destekli bir macOS mola uygulamasidir.

Varsayilan ritim:

- Her 20 dakikada 20 saniyelik goz molasi.
- Her 60 dakikada 5 dakikalik buyuk mola.
- Once macOS bildirimi, 1 dakika sonra aksiyon yoksa ekran ustu panel.

## Research basis

- American Optometric Association: 20-20-20 yaklasimi.
- Mayo Clinic: ekran yorgunlugu icin duzenli goz molalari, kirpma ve uzak odak.
- CDC/NIOSH: bilgisayar basinda saatlik kisa molalarin rahatsizligi azaltabildigine dair is sagligi onerileri.
- Micro-break meta-analysis: kisa molalarin yorgunlugu azaltma ve iyi olusu destekleme bulgulari.

FocusBreak tibbi tedavi araci degildir; saglikli ekran aliskanligi kurmaya yardimci olur.

## App image

The generated app image is stored at:

```text
Resources/AppIcon.png
```

The package script copies it into `dist/FocusBreak.app/Contents/Resources/`, and the app sets it as the runtime Dock icon.

## Build and run

```bash
swift run FocusBreak
```

If SwiftPM cannot write to the default macOS cache folders in a restricted shell, use local package caches:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift run \
  --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security" \
  FocusBreak
```

## Create a shareable app

```bash
./scripts/package_app.sh
```

The unsigned app will be created at:

```text
dist/FocusBreak.app
```

Friends may need to use right click > Open because the app is not Developer ID signed or notarized.
