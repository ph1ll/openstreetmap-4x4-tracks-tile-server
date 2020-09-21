#!/bin/bash

set -x

function createPostgresConfig() {
  cp /etc/postgresql/12/main/postgresql.custom.conf.tmpl /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/12/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderaccount PASSWORD '${PGPASSWORD:-renderaccount}'"
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Set up the database and import /data.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    exit 1
fi

if [ "$1" = "import" ]; then
    # Ensure that database directory is in right state
    chown postgres:postgres -R /var/lib/postgresql
    if [ ! -f /var/lib/postgresql/12/main/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/12/bin/pg_ctl -D /var/lib/postgresql/12/main/ initdb -o "--locale C.UTF-8"
    fi

    # Ensure that tile directory is in right state
    chown renderaccount:renderaccount -R /var/lib/mod_tile

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderaccount 
    sudo -u postgres createdb -E UTF8 -O renderaccount gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderaccount;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderaccount;"
    setPostgresPassword

    # Download Great Britain by default if no data is provided
    if [ ! -f /data.osm.pbf ] && [ -z "$DOWNLOAD_PBF" ]; then
        echo "WARNING: No import file at /data.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="http://download.geofabrik.de/europe/great-britain-latest.osm.pbf"
        DOWNLOAD_POLY="http://download.geofabrik.de/europe/great-britain.poly"
    fi

    if [ -n "$DOWNLOAD_PBF" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget -nv "$DOWNLOAD_PBF" -O /data.osm.pbf
        if [ -n "$DOWNLOAD_POLY" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget -nv "$DOWNLOAD_POLY" -O /data.poly
        fi
    fi

    if [ "$UPDATES" = "enabled" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        osmium fileinfo /data.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
        osmium fileinfo /data.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
        REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -u renderaccount openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data.poly ]; then
        sudo -u renderaccount cp /data.poly /var/lib/mod_tile/data.poly
    fi

    # Configure stylesheet
    if [ -z "$STYLESHEET_REPO" ]; then
        STYLESHEET_REPO="https://github.com/ph1ll/openstreetmap-4x4-tracks-carto.git"
    fi
    mkdir -p /home/renderaccount/src
    cd /home/renderaccount/src
    git clone $STYLESHEET_REPO openstreetmap-carto --depth 1
    cd openstreetmap-carto
    npm install -g carto
    carto project.mml > mapnik.xml

    # Import data
    sudo -u renderaccount osm2pgsql -d gis --create --slim -G --hstore --tag-transform-script /home/renderaccount/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} -S /home/renderaccount/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf ${OSM2PGSQL_EXTRA_ARGS}

    # Create indexes
    sudo -u postgres psql -d gis -f /home/renderaccount/src/openstreetmap-carto/indexes.sql
    
    # Get style external data
    mkdir -p /home/renderaccount/src/openstreetmap-carto/data
    chown renderaccount:renderaccount /home/renderaccount/src/openstreetmap-carto/data
    sudo -u renderaccount /home/renderaccount/src/openstreetmap-carto/scripts/get-external-data.py -c /home/renderaccount/src/openstreetmap-carto/external-data.yml -D /home/renderaccount/src/openstreetmap-carto/data

    # Register that data has changed for mod_tile caching purposes
    touch /var/lib/mod_tile/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" = "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # Fix postgres data privileges
    chown postgres:postgres /var/lib/postgresql -R

    # Fix tile data privileges
    chown renderaccount:renderaccount -R /var/lib/mod_tile

    # Configure Apache CORS
    if [ "$ALLOW_CORS" == "enabled" ] || [ "$ALLOW_CORS" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "$UPDATES" = "enabled" ] || [ "$UPDATES" = "1" ]; then
      /etc/init.d/cron start
    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderaccount renderd -f -c /usr/local/etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
