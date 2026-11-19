#ifndef OSM_SEARCH_PLUGIN_H
#define OSM_SEARCH_PLUGIN_H

#include <QString>
#include "rep_osm_search_source.h"
#include "osm_search_interface.h"
#include "LogosViewPluginBase.h"

class LogosAPI;
class LogosAPIClient;

// OsmSearchPlugin bridges the QML view with two core modules:
//  - `osm` (unchanged SDK) for region resolution, on-chain lookup, Logos
//    Storage fetch, the local catalog, and the open/regions/import/jobs ops —
//    via its generic invokeOpJson.
//  - `osm_search_core` (the standalone Rust search core) for geocode /
//    reverse_geocode / search_build / search_index_status / search_snapshot /
//    job_status — via its generic invoke_op. The search core owns its own
//    SQLite FTS5+rtree indexes and a background build job system; it declares
//    no module dependencies and gets its catalog/cache_dir/pbf paths as
//    invoke_op arguments (the app resolves them via osm at open() time).
//
// QML calls invokeOp(name, argsJson); the plugin routes search ops to the
// search core and everything else to osm, returning the JSON result. This is
// the same forwarding pattern OsmRendererPlugin uses with osm_renderer_core.
//
// The `osm` module is not modified and carries no search code. An osm_app
// user who never installs osm_search never pulls the search core.
class OsmSearchPlugin : public OsmSearchSimpleSource,
                        public OsmSearchInterface,
                        public OsmSearchViewPluginBase
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID OsmSearchInterface_iid FILE "metadata.json")
    Q_INTERFACES(OsmSearchInterface)

public:
    explicit OsmSearchPlugin(QObject* parent = nullptr);
    ~OsmSearchPlugin() override;

    QString name()    const override { return QStringLiteral("osm_search_app"); }
    QString version() const override { return QStringLiteral("0.2.0"); }

    Q_INVOKABLE void initLogos(LogosAPI* api);
    QString invokeOp(QString name, QString argsJson) override;

private:
    void ensureClients();
    // Forward to a core module's generic invoke entry point.
    QString forward(const QString& coreName, const QString& method,
                    const QString& name, const QString& argsJson);
    bool isSearchOp(const QString& name) const;
    // Look up an imported region's PBF path in the osm catalog (empty if not imported).
    QString pbfPathForRegion(const QString& region);

    LogosAPI*       m_api    = nullptr;
    LogosAPIClient* m_osm    = nullptr;        // -> osm core (invokeOpJson)
    LogosAPIClient* m_search = nullptr;       // -> osm_search_core (invoke_op)
};

#endif // OSM_SEARCH_PLUGIN_H
