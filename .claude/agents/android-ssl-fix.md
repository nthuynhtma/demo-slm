# agents/android-ssl-fix.md — Fix Gradle SSL Certificate (Corporate Proxy)

## Role

Agent chuyên xử lý **Gradle SSL/TLS certificate errors** trong môi trường corporate proxy.
Chỉ sửa build environment, **không động vào code app**.

## Trigger

Dùng agent này khi gặp:
- `PKIX path building failed`
- `unable to find valid certification path to requested target`
- `javax.net.ssl.SSLHandshakeException`
- `Could not resolve com.android.tools.build:gradle`
- Gradle download bị block sau corporate proxy

---

## Diagnosis Checklist

Chạy từng lệnh để xác định nguyên nhân:

```bash
# 1. Kiểm tra Java đang dùng
java -version
which java

# 2. Kiểm tra JAVA_HOME
echo $JAVA_HOME

# 3. Test SSL tới Gradle servers
openssl s_client -connect services.gradle.org:443 -showcerts 2>/dev/null | head -30
openssl s_client -connect plugins.gradle.org:443  -showcerts 2>/dev/null | head -30
openssl s_client -connect dl.google.com:443        -showcerts 2>/dev/null | head -30

# 4. Kiểm tra proxy environment
echo $http_proxy
echo $https_proxy
echo $HTTPS_PROXY
```

---

## Fix Strategies (thử theo thứ tự)

### Strategy 1 — Import Corporate CA vào Java keystore

```bash
# Lấy certificate từ proxy
openssl s_client -connect services.gradle.org:443 -showcerts 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/corporate-ca.pem

# Import vào Java cacerts
# macOS (Flutter thường dùng Java trong Android Studio)
JAVA_HOME=$(/usr/libexec/java_home)
sudo keytool -import \
  -alias corporate-ca \
  -keystore "$JAVA_HOME/lib/security/cacerts" \
  -file /tmp/corporate-ca.pem \
  -storepass changeit \
  -noprompt

# Linux
sudo keytool -import \
  -alias corporate-ca \
  -keystore "$JAVA_HOME/jre/lib/security/cacerts" \
  -file /tmp/corporate-ca.pem \
  -storepass changeit \
  -noprompt
```

### Strategy 2 — Gradle properties với proxy + SSL config

Thêm vào `~/.gradle/gradle.properties` (global, không commit):

```properties
# Corporate proxy
systemProp.http.proxyHost=proxy.company.com
systemProp.http.proxyPort=8080
systemProp.https.proxyHost=proxy.company.com
systemProp.https.proxyPort=8080
systemProp.http.nonProxyHosts=localhost|127.0.0.1|*.company.com

# Nếu proxy cần auth
systemProp.http.proxyUser=your_username
systemProp.http.proxyPassword=your_password

# Trust all certs (LAST RESORT - chỉ dùng internal dev)
# systemProp.javax.net.ssl.trustStore=/path/to/truststore.jks
```

### Strategy 3 — Dùng Gradle qua HTTP (không HTTPS)

Sửa `android/gradle/wrapper/gradle-wrapper.properties`:

```properties
# Đổi https → http (chỉ dùng nếu proxy chặn HTTPS)
distributionUrl=http\://services.gradle.org/distributions/gradle-8.x.x-bin.zip
```

> ⚠️ Chỉ dùng tạm thời cho dev environment, không commit lên repo

### Strategy 4 — Download Gradle thủ công + đặt vào cache

```bash
# Download trực tiếp (dùng browser hoặc curl qua proxy)
curl -x http://proxy.company.com:8080 \
  -o ~/Downloads/gradle-8.x.x-bin.zip \
  https://services.gradle.org/distributions/gradle-8.x.x-bin.zip

# Copy vào Gradle cache (bỏ qua download)
mkdir -p ~/.gradle/wrapper/dists/gradle-8.x.x-bin/<hash>/
cp ~/Downloads/gradle-8.x.x-bin.zip ~/.gradle/wrapper/dists/gradle-8.x.x-bin/<hash>/
```

### Strategy 5 — Chỉ định JVM trust store trong Gradle

Tạo `android/gradle.properties` (project-level):

```properties
org.gradle.jvmargs=-Xmx4096m \
  -Djavax.net.ssl.trustStore=/Library/Java/JavaVirtualMachines/jdk-xx/Contents/Home/lib/security/cacerts \
  -Djavax.net.ssl.trustStorePassword=changeit
```

---

## Verify Fix

```bash
# Test Gradle sync
cd android && ./gradlew dependencies --configuration debugRuntimeClasspath

# Nếu pass → build app
cd .. && flutter build apk --debug --dart-define=USE_MOCK=true
```

---

## Output Format

Sau khi áp dụng fix, báo cáo:

```
## SSL Fix Report

**Root cause**: [mô tả nguyên nhân]
**Strategy used**: Strategy [N]
**Commands run**: [liệt kê]
**Result**: ✅ Fixed / ❌ Still failing

**Next step**: [nếu vẫn lỗi → thử Strategy tiếp theo]
```

---

## Notes

- Không sửa bất kỳ file trong `lib/`, `test/`, hay native plugin code
- Mọi thay đổi chỉ ở: `~/.gradle/`, `gradle-wrapper.properties`, Java keystore
- Sau khi fix, revert `gradle-wrapper.properties` nếu đã đổi sang HTTP
