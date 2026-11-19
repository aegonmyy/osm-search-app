// osm_search — "OSM Search". Find places by name or coordinates across the
// OSM regions distributed on Logos.
//
// A standalone consumer of the osm SDK module: every op is forwarded to the
// unchanged osm core over RemoteObjects (invokeOpJson). Search runs against
// the local per-region indexes; a miss recommends what to do next, and
// fetching a region is always an explicit user decision (confirm dialog,
// then a background job with automatic indexing).
//
// Ops are serialized through one pending slot (a QML method call on a
// dynamic replica returns a default value immediately; property sync of
// lastResult is the channel that works, same as osm_renderer). Long work
// (fetch, index build) runs as SDK background jobs polled by a 1 Hz timer.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#141310"

    // ---- Theme ----
    readonly property color cInk:     "#EDE6D6"
    readonly property color cMuted:   "#A89F8C"
    readonly property color cFaint:   "#6E6858"
    readonly property color cTan:     "#C9A23E"
    readonly property color cTeal:    "#3E8F8C"
    readonly property color cHair:    "#3A372E"
    readonly property color cConsole: "#1C1B16"

    FontLoader { id: sansLoader; source: "fonts/PublicSans.ttf" }
    FontLoader { id: monoLoader; source: "fonts/FiraMono.ttf" }
    readonly property string fSans:  sansLoader.status === FontLoader.Ready ? sansLoader.name : "DejaVu Sans"
    readonly property string fMono:  monoLoader.status === FontLoader.Ready ? monoLoader.name : "DejaVu Sans Mono"
    readonly property string fSerif: "Liberation Serif"

    // ---- Backend ----
    readonly property var bk: logos.module("osm_search")

    // ---- Search state ----
    property var    searchResults: []
    property var    searchMiss: null
    property var    searchSelected: null
    property string searchSnapshot: ""
    property bool   searchBusy: false
    property var    reverseResult: null
    property bool   reverseBusy: false
    property var    indexStatuses: []
    property var    jobs: ({})          // job_id -> {label, kind}
    property string activity: ""        // one-line status of running work
    property string pendingRegion: ""   // region awaiting fetch confirmation

    // ---- Serialized op queue ----
    property var    opQueue: []
    property string pendingOp: ""

    function fire(op, args) {
        root.opQueue.push({ op: op, args: args })
        pump()
    }

    function pump() {
        if (root.pendingOp !== "" || !root.bk || root.opQueue.length === 0) return
        const next = root.opQueue.shift()
        root.pendingOp = next.op
        root.bk.invokeOp(next.op, JSON.stringify(next.args))
    }

    Connections {
        target: root.bk
        function onLastResultChanged() {
            if (!root.bk || !root.bk.lastResult.length) return
            let r
            try { r = JSON.parse(root.bk.lastResult) }
            catch (e) { r = { ok: false, error: root.bk.lastResult } }
            root.onResult(r)
        }
    }

    function onResult(r) {
        const op = r.op || root.pendingOp
        root.pendingOp = ""
        switch (op) {
        case "open":
            fire("search_index_status", {})
            break
        case "geocode":
            root.searchBusy = false
            if (r.ok && r.result) {
                root.searchResults = r.result.results || []
                root.searchMiss = r.result.miss || null
            } else {
                root.searchResults = []
                root.searchMiss = { message: r.error || "search failed", hint: "",
                                    hint_has_index: false, indexed_regions: [] }
            }
            rebuildSearchModel()
            break
        case "reverse_geocode":
            root.reverseBusy = false
            root.reverseResult = r.ok ? (r.result || null)
                                      : { error: r.error || "reverse lookup failed" }
            break
        case "search_index_status":
            if (r.ok && r.result) {
                root.indexStatuses = r.result.indexes || []
                rebuildIndexModel()
            }
            break
        case "search_snapshot":
            if (r.ok && r.result && r.result.png_base64)
                root.searchSnapshot = "data:image/png;base64," + r.result.png_base64
            break
        case "search_build":
        case "fetch":
            if (r.ok && r.result && r.result.job_id)
                trackJob(r.result.job_id,
                         op === "fetch" ? "fetching " + (r.result.region || "")
                                        : "indexing " + (r.result.region || ""))
            // A finished import/fetch can nest the auto index job.
            if (r.ok && r.result && r.result.index_job)
                trackJob(r.result.index_job, "indexing " + (r.result.region || ""))
            break
        case "job_status":
            onJobStatus(r)
            break
        }
        pump()
    }

    function trackJob(jobId, label) {
        const next = Object.assign({}, root.jobs)
        next[jobId] = { label: label }
        root.jobs = next
        updateActivity()
    }

    function onJobStatus(r) {
        if (!r.ok || !r.result) return
        const j = r.result
        if (j.state === "running" || j.state === "pending") return
        const next = Object.assign({}, root.jobs)
        delete next[j.job_id]
        root.jobs = next
        if (j.state === "done" && j.op === "search_build") {
            // Indexing finished: refresh the list and clear any selection
            // made against the old index.
            fire("search_index_status", {})
        }
        if (j.state === "done" && j.op === "fetch" && j.result && j.result.index_job)
            trackJob(j.result.index_job, "indexing " + (j.result.region || ""))
        updateActivity()
    }

    function updateActivity() {
        const labels = []
        for (const k in root.jobs) labels.push(root.jobs[k].label)
        root.activity = labels.join(" / ")
    }

    // One job poll per tick, only when the op slot is idle.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            if (root.pendingOp !== "") return
            const ids = Object.keys(root.jobs)
            if (ids.length === 0) return
            fire("job_status", { job_id: ids[0] })
        }
    }

    // ---- Actions ----
    function runSearch() {
        const q = searchQueryField.text.trim()
        if (!q || root.searchBusy) return
        root.searchResults = []
        root.searchMiss = null
        root.searchSelected = null
        root.searchSnapshot = ""
        root.searchBusy = true
        fire("geocode", { query: q, limit: 12 })
    }

    function runReverse() {
        const lat = parseFloat(reverseLat.text.trim())
        const lon = parseFloat(reverseLon.text.trim())
        if (isNaN(lat) || isNaN(lon) || root.reverseBusy) return
        root.reverseResult = null
        root.reverseBusy = true
        fire("reverse_geocode", { lat: lat, lon: lon })
    }

    function selectSearchResult(hit) {
        root.searchSelected = hit
        root.searchSnapshot = ""
        const admin = (hit.admin_path || []).join(", ")
        fire("search_snapshot", {
            region: hit.region, lat: hit.lat, lon: hit.lon,
            label: hit.name || "", admin_path: admin
        })
    }

    function retryWithHint(region) {
        const q = searchQueryField.text.trim()
        const parts = q.split(",").map(s => s.trim()).filter(s => s.length > 0)
        const subject = parts.length > 0 ? parts[0] : q
        searchQueryField.text = subject + ", " + region
        runSearch()
    }

    function buildIndex(region) {
        fire("search_build", { region: region, job: true })
        trackJob(region, "indexing " + region + " (queued)")
    }

    // Fetching is an explicit user decision: the miss panel opens a
    // confirmation, nothing downloads until it is accepted.
    function askFetch(region) {
        root.pendingRegion = region
        fetchDialog.open()
    }

    function confirmFetch() {
        const region = root.pendingRegion
        root.pendingRegion = ""
        fetchDialog.close()
        if (region) fire("fetch", { region: region, job: true })
    }

    function indexedRegionNames() {
        const out = []
        for (let i = 0; i < root.indexStatuses.length; i++)
            if (root.indexStatuses[i].built) out.push(root.indexStatuses[i].region)
        return out
    }

    function fmtCoord(v) { return (v === undefined || v === null) ? "" : v.toFixed(4) }
    function fmtBytes(b) {
        if (b >= 1e9) return (b / 1e9).toFixed(1) + " GB"
        if (b >= 1e6) return (b / 1e6).toFixed(0) + " MB"
        return (b / 1e3).toFixed(0) + " KB"
    }

    function rebuildSearchModel() {
        searchModel.clear()
        for (let i = 0; i < root.searchResults.length; i++) {
            const h = root.searchResults[i]
            searchModel.append({
                name: h.name || "",
                kind: (h.class || "") + " / " + (h.subclass || ""),
                coords: root.fmtCoord(h.lat) + ", " + root.fmtCoord(h.lon),
                admin: (h.admin_path || []).join(" / "),
                region: h.region || ""
            })
        }
    }

    function rebuildIndexModel() {
        indexModel.clear()
        for (let i = 0; i < root.indexStatuses.length; i++) {
            const s = root.indexStatuses[i]
            indexModel.append({
                region: s.region,
                status: s.built ? (s.stale ? "stale" : "indexed") : "not built",
                detail: s.built
                    ? (s.places + " places / " + root.fmtBytes(s.bytes || 0))
                    : "imported, no index yet"
            })
        }
    }

    Component.onCompleted: fire("open", {})

    // ---- Layout ----
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Text {
                text: "OSM Search"
                font.family: root.fSerif
                font.pixelSize: 26
                color: root.cInk
            }
            Text {
                visible: root.activity.length > 0
                Layout.fillWidth: true
                text: root.activity
                font.family: root.fMono
                font.pixelSize: 11
                color: root.cTan
                elide: Text.ElideRight
            }
            Item { Layout.fillWidth: true; visible: root.activity.length === 0 }
            Text {
                text: "local indexes / offline answers"
                font.family: root.fMono
                font.pixelSize: 10
                color: root.cFaint
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: root.cHair }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: contentCol.implicitHeight
            ScrollBar.vertical: ScrollBar { }

            ColumnLayout {
                id: contentCol
                width: parent.width - 8
                spacing: 22

                // -- 01 Search places --
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "Search places"
                        font.family: root.fSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: root.cInk
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Find places by name across the regions indexed on this machine. Nothing leaves this machine. Optionally name the region: Yaba, Lagos."
                        font.family: root.fSans
                        font.pixelSize: 12
                        color: root.cMuted
                        wrapMode: Text.Wrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        TextField {
                            id: searchQueryField
                            Layout.fillWidth: true
                            placeholderText: "e.g. Yaba, Lagos"
                            font.family: root.fSans
                            font.pixelSize: 14
                            color: root.cInk
                            placeholderTextColor: root.cFaint
                            background: Rectangle {
                                radius: 6
                                color: "#1F1E19"
                                border.width: 1
                                border.color: searchQueryField.activeFocus ? root.cTeal : root.cHair
                            }
                            onAccepted: root.runSearch()
                        }
                        Button {
                            text: root.searchBusy ? "Searching…" : "Search"
                            enabled: !root.searchBusy && searchQueryField.text.trim().length > 0
                            font.family: root.fSans
                            font.pixelSize: 13
                            onClicked: root.runSearch()
                        }
                    }
                    Text {
                        visible: root.indexStatuses.length > 0
                        Layout.fillWidth: true
                        text: {
                            const names = root.indexedRegionNames()
                            return names.length === 0
                                ? "No local indexes yet. Import a region, then build its index below."
                                : "Searching: " + names.join(", ")
                        }
                        font.family: root.fMono
                        font.pixelSize: 11
                        color: root.cMuted
                        wrapMode: Text.Wrap
                    }

                    // Miss panel: honest wording, fetch stays a user decision.
                    Rectangle {
                        visible: root.searchMiss !== null
                        Layout.fillWidth: true
                        implicitHeight: missCol.implicitHeight + 20
                        radius: 8
                        color: "#26200F"
                        border.width: 1
                        border.color: "#6B5527"
                        ColumnLayout {
                            id: missCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 8
                            Text {
                                text: root.searchMiss ? root.searchMiss.message : ""
                                font.family: root.fSans
                                font.pixelSize: 13
                                color: root.cTan
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                            RowLayout {
                                visible: root.searchMiss && root.searchMiss.hint
                                spacing: 10
                                Button {
                                    text: "Try \"" + (root.searchMiss ? root.searchMiss.hint : "") + "\""
                                    font.family: root.fSans
                                    font.pixelSize: 12
                                    onClicked: if (root.searchMiss) root.retryWithHint(root.searchMiss.hint)
                                }
                                Button {
                                    text: "Fetch region"
                                    font.family: root.fSans
                                    font.pixelSize: 12
                                    onClicked: if (root.searchMiss) root.askFetch(root.searchMiss.hint)
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Text {
                                text: {
                                    if (!root.searchMiss) return ""
                                    const m = root.searchMiss
                                    return m.indexed_regions && m.indexed_regions.length > 0
                                        ? "Local indexes: " + m.indexed_regions.join(", ") : ""
                                }
                                visible: text.length > 0
                                font.family: root.fMono
                                font.pixelSize: 11
                                color: root.cFaint
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // Results list
                    ListView {
                        visible: root.searchResults.length > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentItem.childrenRect.height,
                                                         46 * root.searchResults.length + 8)
                        clip: true
                        spacing: 2
                        interactive: false
                        model: ListModel { id: searchModel }
                        delegate: Item {
                            width: contentCol.width - 8
                            height: 46
                            Rectangle {
                                anchors.fill: parent
                                radius: 6
                                color: resultMouse.containsMouse ? "#232219" : "transparent"
                                border.width: 1
                                border.color: "#2A2921"
                            }
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 1
                                RowLayout {
                                    spacing: 8
                                    Text {
                                        text: model.name
                                        font.family: root.fSans
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        color: root.cInk
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        text: model.region
                                        font.family: root.fMono
                                        font.pixelSize: 10
                                        color: root.cFaint
                                    }
                                }
                                Text {
                                    text: model.kind + "  ·  " + model.coords +
                                          (model.admin.length > 0 ? "  ·  " + model.admin : "")
                                    font.family: root.fMono
                                    font.pixelSize: 11
                                    color: root.cMuted
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            MouseArea {
                                id: resultMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectSearchResult(root.searchResults[index])
                            }
                        }
                    }
                }

                // -- 02 Selected place --
                ColumnLayout {
                    visible: root.searchSelected !== null
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "Selected place"
                        font.family: root.fSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: root.cInk
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 16
                        Image {
                            id: locatorImage
                            source: root.searchSnapshot
                            fillMode: Image.PreserveAspectFit
                            Layout.preferredWidth: 320
                            Layout.preferredHeight: 240
                            Rectangle {
                                anchors.fill: parent
                                visible: locatorImage.status !== Image.Ready
                                radius: 8
                                color: root.cConsole
                                border.width: 1
                                border.color: root.cHair
                                Text {
                                    anchors.centerIn: parent
                                    text: locatorImage.status === Image.Loading ? "rendering…" : "snapshot"
                                    font.family: root.fSans
                                    font.pixelSize: 12
                                    color: root.cFaint
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                text: root.searchSelected ? root.searchSelected.name : ""
                                font.family: root.fSerif
                                font.pixelSize: 22
                                color: root.cInk
                                wrapMode: Text.Wrap
                            }
                            Text {
                                text: root.searchSelected
                                      ? (root.searchSelected.class + " / " + root.searchSelected.subclass) : ""
                                font.family: root.fMono
                                font.pixelSize: 12
                                color: root.cMuted
                            }
                            Text {
                                text: root.searchSelected
                                      ? (root.fmtCoord(root.searchSelected.lat) + ", " +
                                         root.fmtCoord(root.searchSelected.lon)) : ""
                                font.family: root.fMono
                                font.pixelSize: 12
                                color: root.cTan
                            }
                            Text {
                                visible: root.searchSelected && (root.searchSelected.admin_path || []).length > 0
                                text: root.searchSelected ? (root.searchSelected.admin_path || []).join(" / ") : ""
                                font.family: root.fSans
                                font.pixelSize: 12
                                color: root.cMuted
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                // -- 03 Coordinates to place --
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "Coordinates to place"
                        font.family: root.fSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: root.cInk
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        TextField {
                            id: reverseLat
                            Layout.preferredWidth: 120
                            placeholderText: "latitude"
                            font.family: root.fMono
                            font.pixelSize: 13
                            color: root.cInk
                            placeholderTextColor: root.cFaint
                            background: Rectangle {
                                radius: 6; color: "#1F1E19"
                                border.width: 1
                                border.color: reverseLat.activeFocus ? root.cTeal : root.cHair
                            }
                        }
                        TextField {
                            id: reverseLon
                            Layout.preferredWidth: 120
                            placeholderText: "longitude"
                            font.family: root.fMono
                            font.pixelSize: 13
                            color: root.cInk
                            placeholderTextColor: root.cFaint
                            background: Rectangle {
                                radius: 6; color: "#1F1E19"
                                border.width: 1
                                border.color: reverseLon.activeFocus ? root.cTeal : root.cHair
                            }
                        }
                        Button {
                            text: root.reverseBusy ? "Locating…" : "Locate"
                            enabled: !root.reverseBusy
                            font.family: root.fSans
                            font.pixelSize: 13
                            onClicked: root.runReverse()
                        }
                        Item { Layout.fillWidth: true }
                    }
                    Rectangle {
                        visible: root.reverseResult !== null
                        Layout.fillWidth: true
                        implicitHeight: revCol.implicitHeight + 16
                        radius: 8
                        color: root.cConsole
                        border.width: 1
                        border.color: root.cHair
                        ColumnLayout {
                            id: revCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4
                            Text {
                                text: root.reverseResult && root.reverseResult.name
                                      ? root.reverseResult.name
                                      : (root.reverseResult ? (root.reverseResult.error || "no place found") : "")
                                font.family: root.fSans
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: root.cInk
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                            }
                            Text {
                                visible: root.reverseResult && root.reverseResult.name
                                text: root.reverseResult
                                      ? ((root.reverseResult.class || "") +
                                         (root.reverseResult.distance_m !== undefined
                                          ? "  ·  " + Math.round(root.reverseResult.distance_m) + " m" : "")) : ""
                                font.family: root.fMono
                                font.pixelSize: 11
                                color: root.cMuted
                            }
                            Text {
                                visible: root.reverseResult && (root.reverseResult.admin_path || []).length > 0
                                text: root.reverseResult ? (root.reverseResult.admin_path || []).join(" / ") : ""
                                font.family: root.fSans
                                font.pixelSize: 12
                                color: root.cMuted
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                // -- 04 Local indexes --
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "Local indexes"
                        font.family: root.fSans
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: root.cInk
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "What a query searches. Building an index takes minutes for a full country; it runs as a background job."
                        font.family: root.fSans
                        font.pixelSize: 12
                        color: root.cMuted
                        wrapMode: Text.Wrap
                    }
                    ListView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentItem.childrenRect.height,
                                                         40 * root.indexStatuses.length + 8)
                        clip: true
                        spacing: 2
                        interactive: false
                        model: ListModel { id: indexModel }
                        delegate: Item {
                            width: contentCol.width - 8
                            height: 40
                            Rectangle {
                                anchors.fill: parent
                                radius: 6
                                color: "transparent"
                                border.width: 1
                                border.color: "#2A2921"
                            }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10
                                Text {
                                    text: model.region
                                    font.family: root.fMono
                                    font.pixelSize: 12
                                    color: root.cInk
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: model.detail
                                    font.family: root.fMono
                                    font.pixelSize: 10
                                    color: root.cMuted
                                }
                                Text {
                                    text: model.status
                                    font.family: root.fMono
                                    font.pixelSize: 10
                                    color: model.status === "indexed" ? root.cTeal
                                           : (model.status === "stale" ? root.cTan : root.cFaint)
                                }
                                Button {
                                    visible: model.status !== "indexed"
                                    text: "Build index"
                                    font.family: root.fSans
                                    font.pixelSize: 11
                                    onClicked: root.buildIndex(model.region)
                                }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true; Layout.minimumHeight: 8 }
                }
            }
        }
    }

    // Fetch confirmation: nothing downloads until this is accepted.
    Dialog {
        id: fetchDialog
        modal: true
        title: "Fetch region"
        anchors.centerIn: parent
        standardButtons: Dialog.Cancel
        background: Rectangle { color: "#1F1E19"; radius: 10; border.width: 1; border.color: root.cHair }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "Fetch " + root.pendingRegion + " from Logos Storage?"
                font.family: root.fSans
                font.pixelSize: 14
                color: root.cInk
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }
            Text {
                text: "The verified region data is fetched by its on-chain CID, then indexed automatically. The result may be there once it is fetched and indexed."
                font.family: root.fSans
                font.pixelSize: 12
                color: root.cMuted
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }
            Button {
                text: "Fetch " + root.pendingRegion
                font.family: root.fSans
                font.pixelSize: 13
                Layout.alignment: Qt.AlignRight
                onClicked: root.confirmFetch()
            }
        }
    }
}
