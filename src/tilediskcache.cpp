#include "tilediskcache.h"
#include "nspdssl.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QSslError>
#include <QNetworkRequest>
#include <QCryptographicHash>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QUrl>
#include <QDebug>

namespace {
const qint64 kMaxCacheBytes = 1024LL * 1024LL * 1024LL;

QString sniffExtension(const QByteArray &body)
{
    if (body.size() >= 8 &&
        static_cast<unsigned char>(body[0]) == 0x89 &&
        body[1] == 'P' && body[2] == 'N' && body[3] == 'G')
        return QStringLiteral(".png");
    if (body.size() >= 3 &&
        static_cast<unsigned char>(body[0]) == 0xFF &&
        static_cast<unsigned char>(body[1]) == 0xD8)
        return QStringLiteral(".jpg");
    if (body.size() >= 12 && body.mid(0, 4) == "RIFF" && body.mid(8, 4) == "WEBP")
        return QStringLiteral(".webp");
    return QString();
}
}

TileDiskCache::TileDiskCache(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
    , m_storesSincePrune(0)
{
    m_dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/tiles/raster");
    QDir().mkpath(m_dir);
    qInfo().noquote() << "Кэш тайлов подложки:" << m_dir;
}

QString TileDiskCache::hashName(const QString &url) const
{
    const QByteArray hex = QCryptographicHash::hash(url.toUtf8(), QCryptographicHash::Sha1).toHex();
    return QString::fromLatin1(hex);
}

QString TileDiskCache::existingPath(const QString &url) const
{
    const QString base = m_dir + QLatin1Char('/') + hashName(url);
    const QStringList exts = { QStringLiteral(".jpg"), QStringLiteral(".png"), QStringLiteral(".webp") };
    for (const QString &ext : exts) {
        const QString path = base + ext;
        if (QFileInfo::exists(path) && QFileInfo(path).size() > 32)
            return path;
    }
    return QString();
}

bool TileDiskCache::hasFailed(const QString &url) const
{
    return m_failed.contains(url);
}

QString TileDiskCache::localSource(const QString &url)
{
    if (url.isEmpty() || m_failed.contains(url))
        return QString();
    const QString path = existingPath(url);
    if (!path.isEmpty())
        return QUrl::fromLocalFile(path).toString();
    startDownload(url);
    return QString();
}

void TileDiskCache::startDownload(const QString &url)
{
    if (m_inflight.contains(url) || m_failed.contains(url))
        return;
    QNetworkRequest req{QUrl(url)};
    // Системные корневые + сертификат Минцифры (см. nspdssl.h).
    req.setSslConfiguration(nspdSslConfiguration());
    req.setAttribute(QNetworkRequest::FollowRedirectsAttribute, true);
    // Без таймаута зависший запрос (НСПД недоступна) висит вечно: тайл
    // не грузится и не повторяется, в логе тишина.
    req.setTransferTimeout(20000);
    req.setRawHeader("User-Agent",
                     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                     "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    req.setRawHeader("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8");
    // Подложка НСПД (/api/aeggis/.../wmts): WAF НСПД без Referer отдаёт
    // 403 на API (AGENTS.md §4) — для тайлов ставим тот же Referer, что
    // и CadastralHttp. Что тайлам он нужен, не проверено, но не мешает.
    if (QUrl(url).host().endsWith(QStringLiteral("nspd.gov.ru")))
        req.setRawHeader("Referer", "https://nspd.gov.ru/map?thematic=PKK");
    QNetworkReply *reply = m_nam->get(req);
    m_inflight.insert(url);
    // SSL-отказ тайла — с цепочкой сертификатов (кто подписал), один раз.
    connect(reply, &QNetworkReply::sslErrors, this, [this, reply](const QList<QSslError> &errors) {
        if (m_sslLogged || errors.isEmpty()) return;
        m_sslLogged = true;
        qWarning().noquote() << "Тайлы: ошибка SSL:" << errors.first().errorString()
                             << "; цепочка:" << peerChainText(reply);
    });
    connect(reply, &QNetworkReply::finished, this, [this, url, reply]() {
        finishDownload(url, reply);
        reply->deleteLater();
    });
}

void TileDiskCache::finishDownload(const QString &url, QNetworkReply *reply)
{
    m_inflight.remove(url);
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    // Отменённый по таймауту ответ закрыт — readAll() на нём только
    // сыплет "QIODevice::read: device not open" в лог.
    const QByteArray body = reply->isOpen() ? reply->readAll() : QByteArray();
    const QString ext = sniffExtension(body);
    if (reply->error() != QNetworkReply::NoError || status >= 400 || ext.isEmpty()) {
        // Первые отказы — в консоль приложения: подложку НСПД отсюда не
        // проверить, диагностика только по логу пользователя.
        if (m_warnings < 5) {
            ++m_warnings;
            qWarning().noquote() << "Тайл не загружен:" << url << "HTTP" << status
                                 << reply->errorString()
                                 << (ext.isEmpty() ? QStringLiteral("(ответ не картинка, %1 байт)").arg(body.size())
                                                   : QString());
        }
        // Ответ сервера (4xx/5xx, не картинка) — тайл битый до конца
        // сеанса. Сетевой сбой/таймаут — нет: повторим при следующем
        // показе тайла.
        if (status > 0)
            m_failed.insert(url);
        emit tileFailed(url);
        return;
    }

    const QString path = m_dir + QLatin1Char('/') + hashName(url) + ext;
    QSaveFile out(path);
    if (!out.open(QIODevice::WriteOnly) || out.write(body) != body.size() || !out.commit()) {
        m_failed.insert(url);
        emit tileFailed(url);
        return;
    }

    if (++m_storesSincePrune >= 40) {
        m_storesSincePrune = 0;
        QDir dir(m_dir);
        const QFileInfoList files = dir.entryInfoList(QDir::Files, QDir::Time);
        qint64 total = 0;
        for (const QFileInfo &fi : files)
            total += fi.size();
        if (total > kMaxCacheBytes) {
            for (int i = files.size() - 1; i >= 0 && total > kMaxCacheBytes * 8 / 10; --i) {
                total -= files.at(i).size();
                QFile::remove(files.at(i).absoluteFilePath());
            }
        }
    }
    emit tileStored(url);
}
