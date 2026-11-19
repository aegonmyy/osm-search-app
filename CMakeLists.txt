cmake_minimum_required(VERSION 3.14)
project(OsmSearchPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME osm_search
    REP_FILE src/osm_search.rep
    SOURCES
        src/osm_search_interface.h
        src/osm_search_plugin.h
        src/osm_search_plugin.cpp
)
