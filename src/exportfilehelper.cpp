#include "exportfilehelper.h"

#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QFileInfo>
#include <QDesktopServices>
#include <QDateTime>
#include <QDataStream>
#include <QUrl>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QWindow>

#ifdef Q_OS_WIN
#include <algorithm>
#include <string>
#include <windows.h>
#include <commdlg.h>
#endif

QString ExportFileHelper::reportsDir() const
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation) + "/KadBuffer/exports";
    QDir().mkpath(dir);
    return dir;
}

bool ExportFileHelper::isFileLocked(const QString &path) const
{
    if (!QFileInfo::exists(path))
        return false;
    QFile f(path);
    if (!f.open(QIODevice::ReadWrite))
        return true;
    f.close();
    return false;
}

bool ExportFileHelper::openInDocViewer(const QString &path) const
{
    QFileInfo fi(path);
    if (fi.isFile())
        return QDesktopServices::openUrl(QUrl::fromLocalFile(path));
    const QString target = fi.isDir() ? path : fi.absolutePath();
    return QDesktopServices::openUrl(QUrl::fromLocalFile(target));
}

bool ExportFileHelper::openManual() const
{
    const QString path = QCoreApplication::applicationDirPath() + QStringLiteral("/manual.html");
    if (!QFileInfo::exists(path))
        return false;
    return QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

QString ExportFileHelper::chooseSavePath(const QString &title, const QString &suggestedPath,
                                         const QString &filterName, const QString &ext) const
{
#ifdef Q_OS_WIN
    const QFileInfo fi(suggestedPath);
    QDir().mkpath(fi.absolutePath());

    // Буфер имени: начальное имя файла, дальше сюда же пишется выбор.
    std::wstring file(32768, L'\0');
    const std::wstring name = QDir::toNativeSeparators(fi.fileName()).toStdWString();
    std::copy(name.begin(), name.end(), file.begin());
    const std::wstring dir = QDir::toNativeSeparators(fi.absolutePath()).toStdWString();
    const std::wstring caption = title.toStdWString();
    const std::wstring defExt = ext.toStdWString();
    // Фильтр: "Подпись (*.ext)\0*.ext\0\0".
    std::wstring filter = (filterName + QStringLiteral(" (*.") + ext + QStringLiteral(")")).toStdWString();
    filter.push_back(L'\0');
    filter += (QStringLiteral("*.") + ext).toStdWString();
    filter.push_back(L'\0');
    filter.push_back(L'\0');

    OPENFILENAMEW ofn;
    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    QWindow *w = QGuiApplication::focusWindow();
    if (!w && !QGuiApplication::topLevelWindows().isEmpty())
        w = QGuiApplication::topLevelWindows().first();
    ofn.hwndOwner = w ? reinterpret_cast<HWND>(w->winId()) : nullptr;
    ofn.lpstrFilter = filter.c_str();
    ofn.lpstrFile = &file[0];
    ofn.nMaxFile = DWORD(file.size());
    ofn.lpstrInitialDir = dir.c_str();
    ofn.lpstrTitle = caption.c_str();
    ofn.lpstrDefExt = defExt.c_str();
    ofn.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetSaveFileNameW(&ofn))
        return QString();
    return QDir::fromNativeSeparators(QString::fromWCharArray(file.c_str()));
#else
    Q_UNUSED(title) Q_UNUSED(filterName) Q_UNUSED(ext)
    return suggestedPath;
#endif
}

namespace {

quint32 crc32(const QByteArray &data)
{
    static quint32 table[256];
    static bool ready = false;
    if (!ready) {
        for (quint32 i = 0; i < 256; ++i) {
            quint32 c = i;
            for (int k = 0; k < 8; ++k)
                c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = true;
    }
    quint32 crc = 0xFFFFFFFFu;
    for (char ch : data)
        crc = table[(crc ^ static_cast<quint8>(ch)) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

struct ZipEntry {
    QByteArray name;
    quint16 method;
    quint32 crc;
    quint32 compressedSize;
    quint32 size;
    quint32 offset;
};

} // namespace

QString ExportFileHelper::writeZip(const QString &path, const QVariantMap &entries) const
{
    if (isFileLocked(path))
        return QStringLiteral("файл открыт в другой программе, закройте его: ")
                + QFileInfo(path).fileName();

    // Время модификации в формате MS-DOS — одно на все записи.
    const QDateTime now = QDateTime::currentDateTime();
    const quint16 dosTime = quint16((now.time().hour() << 11) | (now.time().minute() << 5)
                                    | (now.time().second() / 2));
    const quint16 dosDate = quint16(((now.date().year() - 1980) << 9)
                                    | (now.date().month() << 5) | now.date().day());

    QByteArray zip;
    QDataStream out(&zip, QIODevice::WriteOnly);
    out.setByteOrder(QDataStream::LittleEndian);
    QList<ZipEntry> written;

    // QVariantMap обходится по алфавиту: "[Content_Types].xml" идёт
    // первым, как принято в OOXML.
    for (auto it = entries.constBegin(); it != entries.constEnd(); ++it) {
        ZipEntry e;
        e.name = it.key().toUtf8();
        const QByteArray data = it.value().toString().toUtf8();
        e.crc = crc32(data);
        e.size = quint32(data.size());
        // qCompress = 4 байта длины + zlib (2 байта заголовка, deflate,
        // 4 байта adler32). В zip нужен «голый» deflate — середина.
        const QByteArray z = qCompress(data, 9);
        QByteArray payload = z.mid(6, z.size() - 10);
        e.method = 8;
        if (payload.size() >= data.size()) {
            payload = data;
            e.method = 0;
        }
        e.compressedSize = quint32(payload.size());
        e.offset = quint32(zip.size());

        out << quint32(0x04034b50) << quint16(20) << quint16(0x0800) << e.method
            << dosTime << dosDate << e.crc << e.compressedSize << e.size
            << quint16(e.name.size()) << quint16(0);
        out.writeRawData(e.name.constData(), e.name.size());
        out.writeRawData(payload.constData(), payload.size());
        written << e;
    }

    const quint32 cdOffset = quint32(zip.size());
    for (const ZipEntry &e : written) {
        out << quint32(0x02014b50) << quint16(20) << quint16(20) << quint16(0x0800) << e.method
            << dosTime << dosDate << e.crc << e.compressedSize << e.size
            << quint16(e.name.size()) << quint16(0) << quint16(0) << quint16(0)
            << quint16(0) << quint32(0) << e.offset;
        out.writeRawData(e.name.constData(), e.name.size());
    }
    const quint32 cdSize = quint32(zip.size()) - cdOffset;
    out << quint32(0x06054b50) << quint16(0) << quint16(0)
        << quint16(written.size()) << quint16(written.size())
        << cdSize << cdOffset << quint16(0);

    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write(zip) != zip.size() || !f.commit())
        return QStringLiteral("не удалось записать ") + QFileInfo(path).fileName()
                + QStringLiteral(": ") + f.errorString();
    return QString();
}
