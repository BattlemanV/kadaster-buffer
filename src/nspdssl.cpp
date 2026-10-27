#include "nspdssl.h"

#include <QNetworkReply>
#include <QSslCertificate>
#include <QStringList>
#include <QDebug>

QSslConfiguration nspdSslConfiguration()
{
    static QSslConfiguration conf = [] {
        QSslConfiguration c = QSslConfiguration::defaultConfiguration();
        QList<QSslCertificate> cas = QSslConfiguration::systemCaCertificates();
        const QList<QSslCertificate> pinned =
                QSslCertificate::fromPath(QStringLiteral(":/certs/russian_trusted_root_ca.pem"));
        if (pinned.isEmpty())
            qWarning().noquote() << "Сертификат Минцифры не найден в ресурсах — НСПД может не открыться";
        cas += pinned;
        c.setCaCertificates(cas);
        return c;
    }();
    return conf;
}

QString peerChainText(QNetworkReply *reply)
{
    if (!reply)
        return QString();
    QStringList parts;
    for (const QSslCertificate &c : reply->sslConfiguration().peerCertificateChain()) {
        const QStringList cn = c.subjectInfo(QSslCertificate::CommonName);
        const QStringList org = c.subjectInfo(QSslCertificate::Organization);
        QString name = cn.isEmpty() ? QStringLiteral("?") : cn.first();
        if (!org.isEmpty())
            name += QStringLiteral(" (") + org.first() + QStringLiteral(")");
        parts << name;
    }
    return parts.join(QStringLiteral(" <- "));
}
