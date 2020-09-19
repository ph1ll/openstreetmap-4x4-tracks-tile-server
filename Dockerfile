FROM ubuntu:20.04

# Based on
# https://switch2osm.org/serving-tiles/manually-building-a-tile-server-20-04-lts/

# Set up environment
ENV TZ=UTC
ENV AUTOVACUUM=on
ENV UPDATES=disabled
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install requird packages
RUN apt-get update && apt-get install -y --no-install-recommends \
   libboost-all-dev \
   git \
   tar \
   unzip \
   wget \
   bzip2 \
   build-essential \
   autoconf \
   libtool \
   libxml2-dev \
   libgeos-dev \
   libgeos++-dev \
   libpq-dev \
   libbz2-dev \
   libproj-dev \
   munin-node \
   munin \
   protobuf-c-compiler \
   libfreetype6-dev \
   libtiff5-dev \
   libicu-dev \
   libgdal-dev \
   libcairo2-dev \
   libcairomm-1.0-dev \
   apache2 \
   apache2-dev \
   libagg-dev \
   liblua5.2-dev \
   ttf-unifont \
   lua5.1 \
   liblua5.1-0-dev \
   postgresql \
   postgresql-contrib \
   postgis \
   postgresql-12-postgis-3 \
   postgresql-12-postgis-3-scripts \
   osm2pgsql \
   autoconf \
   apache2-dev \
   libtool \
   libxml2-dev \
   libbz2-dev \
   libgeos-dev \
   libgeos++-dev \
   libproj-dev \
   gdal-bin \
   libmapnik-dev \
   mapnik-utils \
   python3-mapnik \
   python3-psycopg2 \
   npm \
   fonts-noto-cjk \
   fonts-noto-hinted \
   fonts-noto-unhinted \
   ttf-unifont \
   sudo \
   python3-yaml \
   python3-requests \
   osmium-tool \
   osmosis \
   python3-lxml \
   python3-shapely \
&& apt-get clean autoclean \
&& apt-get autoremove -y \
&& rm -rf /var/lib/{apt,dpkg,cache,log}

RUN update-alternatives --install /usr/local/bin/python python /usr/bin/python3 10

# Create renderaccount user
RUN useradd -m renderaccount

# Install mod_tile and renderd
RUN mkdir -p /home/renderaccount/src \
 && cd /home/renderaccount/src \
 && git clone -b switch2osm https://github.com/SomeoneElseOSM/mod_tile.git --depth 1 \
 && cd mod_tile \
 && rm -rf .git \
 && ./autogen.sh \
 && ./configure \
 && make -j $(nproc) \
 && make -j $(nproc) install \
 && make -j $(nproc) install-mod_tile \
 && ldconfig \
 && cd ..

# Configure renderd
RUN sed -i 's/hot/tile/g' /usr/local/etc/renderd.conf

# Configure Apache
RUN mkdir /var/lib/mod_tile \
 && chown renderaccount /var/lib/mod_tile \
 && mkdir /var/run/renderd \
 && chown renderaccount /var/run/renderd \
 && echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf \
 && echo "LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so" >> /etc/apache2/conf-available/mod_headers.conf \
 && a2enconf mod_tile && a2enconf mod_headers
COPY apache.conf /etc/apache2/sites-available/000-default.conf
COPY leaflet-demo.html /var/www/html/index.html
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
 && ln -sf /dev/stderr /var/log/apache2/error.log

# Configure PosgtreSQL
COPY postgresql.custom.conf.tmpl /etc/postgresql/12/main/
RUN chown -R postgres:postgres /var/lib/postgresql \
 && chown postgres:postgres /etc/postgresql/12/main/postgresql.custom.conf.tmpl \
 && echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/12/main/pg_hba.conf \
 && echo "host all all ::/0 md5" >> /etc/postgresql/12/main/pg_hba.conf

# Copy update scripts
COPY openstreetmap-tiles-update-expire /usr/bin/
RUN chmod +x /usr/bin/openstreetmap-tiles-update-expire \
 && mkdir /var/log/tiles \
 && chmod a+rw /var/log/tiles \
 && ln -s /home/renderaccount/src/mod_tile/osmosis-db_replag /usr/bin/osmosis-db_replag \
 && echo "*  *    * * *   renderaccount    openstreetmap-tiles-update-expire\n" >> /etc/crontab

# Install trim_osc.py helper script
RUN mkdir -p /home/renderaccount/src \
 && cd /home/renderaccount/src \
 && git clone https://github.com/zverik/regional \
 && cd regional \
 && git checkout 612fe3e040d8bb70d2ab3b133f3b2cfc6c940520 \
 && rm -rf .git \
 && chmod u+x /home/renderaccount/src/regional/trim_osc.py

# Start running
COPY run.sh /
ENTRYPOINT ["/run.sh"]
CMD []

EXPOSE 80 5432
