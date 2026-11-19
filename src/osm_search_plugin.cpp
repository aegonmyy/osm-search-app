#include "osm_search_plugin.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "logos_api.h"
#include "logos_api_client.h"

OsmSearchPlugin::OsmSearchPlugin(QObject* parent)
    : OsmSearchSimpleSource(parent)
{
}

OsmSearchPlugin::~OsmSearchPlugin()
{
    delete m_osm;
    delete m_search;
}

void OsmSearchPlugin::initLogos(LogosAPI* api)
{
    m_api = api;
    setBackend(this);
    ensureClients();
}

void OsmSearchPlugin::ensureClients()
{
    if (m_osm && m_search) {
        return;
    }
    if (!m_api) {
        return;
    }
    // This replica is "osm_search"; the two cores it forwards to are "osm"
    // (the unchanged SDK) and "osm_search_core" (the standalone Rust search
    // core that owns the SQLite FTS5+rtree indexes + background job system).
    if (!m_osm) {
        m_osm = new LogosAPIClient(
            QStringLiteral("osm"),
            QStringLiteral("osm_search"),
            m_api->getTokenManager(),
            this);
    }
    if (!m_search) {
        m_search = new LogosAPIClient(
            QStringLiteral("osm_search_core"),
            QStringLiteral("osm_search"),
            m_api->getTokenManager(),
            this);
    }
}

QString OsmSearchPlugin::forward(const QString& coreName, const QString& method,
                                 const QString& name, const QString& argsJson)
{
    ensureClients();
    LogosAPIClient* client = (coreName == QLatin1String("osm")) ? m_osm : m_search;
    if (!client) {
        return QStringLiteral("{\"ok\":false,\"error\":\"no %1 client\"}").arg(coreName);
    }
    return client->invokeRemoteMethod(coreName, method, name, argsJson).toString();
}

bool OsmSearchPlugin::isSearchOp(const QString& name) const
{
    // Search ops live in the osm_search_core module (its generic invoke_op).
    // open / regions / catalog / fetch / import / job_status-for-fetch and
    // everything else stay with the osm core (its invokeOpJson). `open` is
    // special-cased below (two-stage seed). `search_build` is special-cased
    // below (resolve the imported pbf path from the osm catalog, then forward
    // with an explicit pbf to the search core). `job_status` is routed by
    // job_id prefix (sb- -> search core; else osm) below.
    return name == QStringLiteral("geocode")
        || name == QStringLiteral("reverse_geocode")
        || name == QStringLiteral("search_index_status")
        || name == QStringLiteral("search_snapshot");
}

// Look up an imported region's PBF path in the osm catalog. The osm `catalog`
// op returns one entry per imported region with a `path` field pointing at the
// local .osm.pbf. Returns an empty string if the region is not imported.
QString OsmSearchPlugin::pbfPathForRegion(const QString& region)
{
    const QString cat = forward(QStringLiteral("osm"),
                                QStringLiteral("invokeOpJson"),
                                QStringLiteral("catalog"),
                                QStringLiteral("{}"));
    const QJsonDocument doc = QJsonDocument::fromJson(cat.toUtf8());
    if (!doc.isObject()) return QString();
    const QJsonArray arr = doc.object().value(QStringLiteral("result")).toArray();
    for (const QJsonValue& v : arr) {
        const QJsonObject o = v.toObject();
        if (o.value(QStringLiteral("region")).toString() == region) {
            return o.value(QStringLiteral("path")).toString();
        }
    }
    return QString();
}

QString OsmSearchPlugin::invokeOp(QString name, QString argsJson)
{
    // -- open: two-stage seed -------------------------------------------
    // Fetch the osm open result (carries cache_dir) + the osm catalog
    // (region + md5 per imported region), then seed the search engine with
    // {cache_dir, catalog} via osm_search_core.invoke_op("open"). The osm
    // open result is what the QML reads (it then fires search_index_status).
    if (name == QStringLiteral("open")) {
        const QString osmState = forward(QStringLiteral("osm"),
                                         QStringLiteral("invokeOpJson"),
                                         QStringLiteral("open"), argsJson);
        const QJsonObject osmObj =
            QJsonDocument::fromJson(osmState.toUtf8()).object();
        const QString cat = forward(QStringLiteral("osm"),
                                   QStringLiteral("invokeOpJson"),
                                   QStringLiteral("catalog"),
                                   QStringLiteral("{}"));
        const QJsonArray catArr =
            QJsonDocument::fromJson(cat.toUtf8()).object()
                .value(QStringLiteral("result")).toArray();

        QJsonObject engineArgs;
        // cache_dir / data_dir from the osm open result.
        if (osmObj.contains(QStringLiteral("result"))) {
            const QJsonObject r = osmObj.value(QStringLiteral("result")).toObject();
            if (r.contains(QStringLiteral("cache_dir")))
                engineArgs[QStringLiteral("cache_dir")] = r.value(QStringLiteral("cache_dir"));
            else if (r.contains(QStringLiteral("data_dir")))
                engineArgs[QStringLiteral("cache_dir")] = r.value(QStringLiteral("data_dir"));
        }
        QJsonArray catalog;
        for (const QJsonValue& v : catArr) {
            const QJsonObject o = v.toObject();
            QJsonObject e;
            e[QStringLiteral("region")] = o.value(QStringLiteral("region"));
            e[QStringLiteral("md5")]    = o.value(QStringLiteral("md5"));
            catalog.append(e);
        }
        engineArgs[QStringLiteral("catalog")] = catalog;

        // Best-effort seed: ignore failures (search ops will report
        // "not open" themselves if this didn't land).
        if (m_search) {
            const QByteArray a = QJsonDocument(engineArgs).toJson(QJsonDocument::Compact);
            (void)forward(QStringLiteral("osm_search_core"),
                          QStringLiteral("invoke_op"),
                          QStringLiteral("open"), QString::fromUtf8(a));
        }
        setLastResult(osmState);
        setLastErr(QStringLiteral(""));
        return osmState;
    }

    // -- search_build: resolve the pbf path, then forward ---------------
    // The QML fires search_build {region, job:true}. The standalone search
    // core has no osm state and needs an explicit pbf path, so resolve it
    // from the osm catalog (the imported region's `path`) and inject it.
    if (name == QStringLiteral("search_build")) {
        const QJsonObject args =
            QJsonDocument::fromJson(argsJson.toUtf8()).object();
        const QString region =
            args.value(QStringLiteral("region")).toString();
        QString pbf = args.value(QStringLiteral("pbf")).toString();
        if (pbf.isEmpty() && !region.isEmpty()) {
            pbf = pbfPathForRegion(region);
        }
        if (pbf.isEmpty()) {
            const QString msg = QStringLiteral(
                "region %1 has no imported PBF in the osm catalog — "
                "import or fetch it first, or pass an explicit pbf path")
                .arg(region);
            setLastResult(msg);
            setLastErr(msg);
            return msg;
        }
        QJsonObject fwd = args;
        fwd[QStringLiteral("pbf")] = pbf;
        const QString af = QJsonDocument(fwd).toJson(QJsonDocument::Compact);
        const QString result = forward(QStringLiteral("osm_search_core"),
                                        QStringLiteral("invoke_op"),
                                        QStringLiteral("search_build"), af);
        setLastResult(result);
        const QJsonDocument doc = QJsonDocument::fromJson(result.toUtf8());
        if (doc.isObject() && !doc.object().value(QLatin1String("ok")).toBool())
            setLastErr(doc.object().value(QLatin1String("error")).toString());
        else
            setLastErr(QStringLiteral(""));
        return result;
    }

    // -- job_status: route by job_id prefix ----------------------------
    // osm fetch/import jobs live in osm; search index builds live in
    // osm_search_core (job ids are "sb-<ms>"). Route by prefix.
    if (name == QStringLiteral("job_status")) {
        const QJsonObject args =
            QJsonDocument::fromJson(argsJson.toUtf8()).object();
        const QString id = args.value(QStringLiteral("job_id")).toString();
        const QString coreName = id.startsWith(QStringLiteral("sb-"))
            ? QStringLiteral("osm_search_core")
            : QStringLiteral("osm");
        const QString method = (coreName == QLatin1String("osm_search_core"))
            ? QStringLiteral("invoke_op")
            : QStringLiteral("invokeOpJson");
        const QString result = forward(coreName, method, name, argsJson);
        setLastResult(result);
        setLastErr(QStringLiteral(""));
        return result;
    }

    // -- default: search ops -> search core, everything else -> osm ----
    QString result;
    if (isSearchOp(name)) {
        result = forward(QStringLiteral("osm_search_core"),
                         QStringLiteral("invoke_op"), name, argsJson);
    } else {
        result = forward(QStringLiteral("osm"),
                         QStringLiteral("invokeOpJson"), name, argsJson);
    }
    setLastResult(result);
    const QJsonDocument doc = QJsonDocument::fromJson(result.toUtf8());
    if (doc.isObject() && !doc.object().value(QLatin1String("ok")).toBool())
        setLastErr(doc.object().value(QLatin1String("error")).toString());
    else
        setLastErr(QStringLiteral(""));
    return result;
}
