#ifndef NSPDSSL_H
#define NSPDSSL_H

#include <QSslConfiguration>
#include <QString>

class QNetworkReply;

// TLS для НСПД. nspd.gov.ru подписан российским корневым сертификатом
// «Russian Trusted Root CA» (Минцифры). Windows ему из коробки не
// доверяет — его ставят отдельно (Госуслуги). На компьютере без него
// любой запрос падал: «The root certificate of the certificate chain is
// self-signed, and untrusted».
//
// Решение — НЕ отключать проверку, а добавить к системным корневым
// ровно этот сертификат (resources/certs/russian_trusted_root_ca.pem,
// SHA-1 8FF915CCAB7BC16F8C5C8099D53E0E115B3AEC2F, до 28.02.2032; сверен
// побайтно: gu-st.ru и хранилище Windows). Цепочку, срок и имя хоста
// OpenSSL проверяет как обычно.
//
// Настройки ставятся на КАЖДЫЙ запрос: QNetworkAccessManager держит
// соединение к хосту с SSL-настройками первого запроса.
QSslConfiguration nspdSslConfiguration();

// "лист <- промежуточный <- корневой" — для лога при SSL-ошибке: видно,
// чей сертификат пришёл (Минцифры, антивирус с проверкой https, прокси).
QString peerChainText(QNetworkReply *reply);

#endif // NSPDSSL_H
