# GNL-Translete

Türkçe arayüzlü, çevrimdışı çalışan iPhone çeviri ve İngilizce pratik uygulaması (SwiftUI, iOS 26+).

## Cihaz içi bileşenler

| İş | Bileşen | Lisans | Boyut | Not |
|---|---|---|---|---|
| Konuşma tanıma | Apple Speech (tr-TR + en-US, `requiresOnDeviceRecognition`) | iOS | iPhone indirir | İki tanıyıcı aynı sesi paralel işler; dil, güven + NaturalLanguage ile seçilir |
| Çeviri | Apple Translation (`TranslationSession`) | iOS | ~100–200 MB | İlk kurulumda indirilir |
| Yeni cevap + ton | Qwen2.5-1.5B-Instruct Q4_K_M (llama.cpp, Metal) | Apache 2.0 | ~1,1 GB | Apple Intelligence gerektirmez |
| Ton ön değerlendirme | Sözcük listesi (TR/EN) + model çıktısı | – | – | Belirsizse "… olabilir" |
| Seslendirme | AVSpeechSynthesizer, iPhone'daki hazır sesler | iOS | – | Ek ses indirmek zorunlu değil |
| Canlı kamera | VisionKit DataScanner + Apple Translation | iOS | – | Fotoğraf çekmez, sesli okumaz |
| Telaffuz / pratik | Apple Speech (en-US) + NLEmbedding | iOS | – | Kayıt belirsizse kesin hata söylemez |

İnternet yalnızca ilk indirme ve güncellemeler için kullanılır. Konuşmalar, kamera görüntüleri ve pratik verileri sunucuya gönderilmez.

## Derleme (Mac gerekmez)

`main` dalına her gönderimde GitHub Actions (macOS 26) şunları yapar:
1. En güncel llama.cpp XCFramework'ünü indirir.
2. XcodeGen ile `GNLTranslete.xcodeproj` oluşturur.
3. İmzasız derler ve `GNL-Translete.ipa` dosyasını **Releases** bölümüne koyar.

## iPhone'a yükleme (ücretsiz Apple hesabı)

1. Windows'a Apple'ın sitesinden iTunes + iCloud, ardından AltServer kur.
2. iPhone'u bağla, AltServer → Install AltStore.
3. iPhone: Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu (aç), Ayarlar → Genel → VPN ve Aygıt Yönetimi → Güven.
4. Releases'tan .ipa'yı indir → AltStore → Uygulamalarım → +.
5. İlk açılışta Wi-Fi'de modelleri indir. 7 günlük imza, AltServer açıkken aynı Wi-Fi'de kendiliğinden yenilenir.

## Durum (v0.1.0)

- [x] Tüm ekranlar ve akışlar kodlandı (ana ekran, Cümlemi Çevir, Karşıya Oku, Kamera, Kaydedilenler, Pratik, Telaffuz, Hazır Arşiv, Görünüm, Ses ve Konuşma, Yeni Sohbet).
- [ ] **Henüz derlenmedi.** İlk derleme GitHub Actions'ta yapılacak; çıkan hatalar düzeltilecek.
- [ ] **Hazır Arşiv içeriği boş** (`GNLTranslete/Resources/archive.json`). Altyapı, arama, seslendirme, pratik ve 5.000/3.000/1.000 adet doğrulaması hazır; içerik 2. aşamada eklenecek.
- [ ] **Fiziksel cihazda doğrulanan model: yok.** iPhone 15/16/17/18 ailesinin hiçbiri henüz denenmedi.

## Bekleyen kabul testleri (fiziksel cihaz)

- Uçak modu + Wi-Fi kapalı + Bluetooth açık: iki modda otomatik dinleme, arşivde olmayan cümle çevirisi, AirPods'tan cevap.
- Türkçe, karışık, aksanlı/eksik İngilizce; konu değişimi, bağlantılı konu, eski konuya dönüş; şaka, alay, sert dil, belirsizlik.
- AirPods'u seslendirme sırasında çıkarma: hoparlörden ses çıkmaması, bağlamın korunması, geri takınca devam.
- Karşıya Oku'nun yalnızca seçili çeviriyi hoparlörden vermesi, sonraki sesin kulaklığa dönmesi.
- Sessiz canlı kamera, yazarak/konuşarak Cümlemi Çevir, telaffuz geri bildirimi.
- Yeni Sohbet onayı, yeniden açılış, kayıt/klasör koruması, yarım pratik, iki kez atlama, iki ayrı turda Bildim.
- Hazır seslerle çevrimdışı başlama, ses önizleme, dil başına hız, tema önizleme, tercihlerin korunması.
- Ölçümler: konuşma bitişi → ilk çeviri sesi, → ilk İngilizce cevap sesi; kaçırılan sözler; bellek; kurulum boyutu; uzun oturum.
