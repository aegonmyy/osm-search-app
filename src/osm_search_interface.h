#ifndef OSM_SEARCH_INTERFACE_H
#define OSM_SEARCH_INTERFACE_H

#include <QObject>
#include <QString>

#include "interface.h"

// Marker interface for the OSM Search view plugin. All logic lives in
// OsmSearchPlugin; this header supplies the IID used by Q_PLUGIN_METADATA.
class OsmSearchInterface : public PluginInterface
{
public:
    virtual ~OsmSearchInterface() = default;
};

#define OsmSearchInterface_iid "org.logos.OsmSearchInterface/1"
Q_DECLARE_INTERFACE(OsmSearchInterface, OsmSearchInterface_iid)

#endif // OSM_SEARCH_INTERFACE_H
