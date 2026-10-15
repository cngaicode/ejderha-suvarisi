# Ejderha Süvarisi — Alp Vadisi (v1.2)

İsviçre Alpleri'ni andıran tek haritalı, açık dünya ejderha uçuş oyunu. Godot 4.7, tek script (`game/ejderha.gd`).
PC'de klavye/fare/oyun kolu, iPhone'da dokunmatik kontrollerle oynanır.

## iPhone'a kurulum (Mac gerekmez)

Bu depoya her değişiklik gönderildiğinde GitHub'ın bulut Mac'i oyunu otomatik derler ve
**Releases → "iPhone — son sürüm"** sayfasına `EjderhaSuvarisi.ipa` dosyasını koyar.

### Bir kerelik hazırlık (Windows PC)
1. **iTunes** ve **iCloud**'u Apple'ın sitesinden indirip kur (Microsoft Store sürümleri değil — Sideloadly web sürümlerini istiyor).
2. **Sideloadly**'yi indir ve kur: https://sideloadly.io
3. iPhone'u kabloyla PC'ye bağla, telefonda **"Bu Bilgisayara Güven"** de.

### Kurulum
1. Bu deponun **Releases** bölümünden `EjderhaSuvarisi.ipa` dosyasını PC'ye indir.
2. Sideloadly'yi aç; üstte iPhone'unun seçili olduğunu gör.
3. `.ipa` dosyasını Sideloadly'deki IPA kutusuna sürükle.
4. **Apple ID** kutusuna kendi Apple ID e-postanı yaz → **Start**. Şifre ve gerekirse iki adımlı doğrulama kodu ister.
5. "Done" yazınca uygulama telefonda görünür.

### Telefonda ilk açılış
1. **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu**'nu aç, telefon yeniden başlar, "Aç" de.
   (Bu seçenek, ilk kurulum denemesinden sonra görünür.)
2. **Ayarlar → Genel → VPN ve Cihaz Yönetimi →** Apple ID'ne tıkla → **Güven**.
3. Ejderha Süvarisi'ni aç. Telefonu yatay tut.

### 7 gün kuralı
Ücretsiz Apple ID ile kurulan uygulamalar **7 gün** sonra açılmaz. Sideloadly ile aynı `.ipa`'yı tekrar
kurman yeterli (kayıtların silinmez). Ücretsiz hesapla aynı anda en fazla 3 uygulama bu şekilde kurulabilir.

## Dokunmatik kontroller
- **Sol alt joystick:** ileri = kanat çırp / hızlan, geri = fren (yavaşken havada asılı kal), sağ-sol = yatış. Yayayken yürü.
- **Ekranda parmak sürükle:** bak ve ejderhayı yönlendir.
- **ATEŞ** (basılı tut), **KANAT** (güçlü vuruş / kalkış), **DALIŞ** (basılı tut), **HIZ** (aç/kapa),
  **KÜKRE**, **İN/BİN**, **ÇAĞIR**, **TÜR**, **HARİTA**, **☰** menü (grafik kalitesi), **?** yardım.
- Bluetooth PlayStation / Xbox kolu da çalışır.

## PC'de çalıştırma
Godot 4.7 → İçe Aktar → `game/project.godot` → F5. Ayrıntılar: `game/OKU_BENI.txt`.
