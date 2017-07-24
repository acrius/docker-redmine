#!/bin/bash
set -e

GEM_CACHE_DIR="${REDMINE_BUILD_DIR}/cache"

BUILD_DEPENDENCIES="libcurl4-openssl-dev libssl-dev libmagickcore-dev libmagickwand-dev \
                    libmysqlclient-dev libpq-dev libxslt1-dev libffi-dev libyaml-dev"

## Execute a command as REDMINE_USER
exec_as_redmine() {
  sudo -HEu ${REDMINE_USER} "$@"
}

# install build dependencies
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${BUILD_DEPENDENCIES}

# add ${REDMINE_USER} user
adduser --disabled-login --gecos 'Redmine' ${REDMINE_USER}
passwd -d ${REDMINE_USER}

# set PATH for ${REDMINE_USER} cron jobs
cat > /tmp/cron.${REDMINE_USER} <<EOF
REDMINE_USER=${REDMINE_USER}
REDMINE_INSTALL_DIR=${REDMINE_INSTALL_DIR}
REDMINE_DATA_DIR=${REDMINE_DATA_DIR}
REDMINE_RUNTIME_DIR=${REDMINE_RUNTIME_DIR}
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
EOF
crontab -u ${REDMINE_USER} /tmp/cron.${REDMINE_USER}
rm -rf /tmp/cron.${REDMINE_USER}

# install redmine, use local copy if available
exec_as_redmine mkdir -p ${REDMINE_INSTALL_DIR}
if [[ -f ${REDMINE_BUILD_DIR}/redmine-${REDMINE_VERSION}.tar.gz ]]; then
  exec_as_redmine tar -zvxf ${REDMINE_BUILD_DIR}/redmine-${REDMINE_VERSION}.tar.gz --strip=1 -C ${REDMINE_INSTALL_DIR}
else
  echo "Downloading Redmine ${REDMINE_VERSION}..."
  exec_as_redmine wget "http://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz" -O /tmp/redmine-${REDMINE_VERSION}.tar.gz

  echo "Extracting..."
  exec_as_redmine tar -zxf /tmp/redmine-${REDMINE_VERSION}.tar.gz --strip=1 -C ${REDMINE_INSTALL_DIR}

  exec_as_redmine rm -rf /tmp/redmine-${REDMINE_VERSION}.tar.gz
fi

# HACK: we want both the pg and mysql2 gems installed, so we remove the
#       respective lines and add them at the end of the Gemfile so that they
#       are both installed.
PG_GEM=$(grep 'gem "pg"' ${REDMINE_INSTALL_DIR}/Gemfile | awk '{gsub(/^[ \t]+|[ \t]+$/,""); print;}')
MYSQL2_GEM=$(grep 'gem "mysql2"' ${REDMINE_INSTALL_DIR}/Gemfile | awk '{gsub(/^[ \t]+|[ \t]+$/,""); print;}')

sed -i \
  -e '/gem "pg"/d' \
  -e '/gem "mysql2"/d' \
  ${REDMINE_INSTALL_DIR}/Gemfile

(
  echo "${PG_GEM}";
  echo "${MYSQL2_GEM}";
  echo 'gem "unicorn"';
  echo 'gem "dalli", "~> 2.7.0"';
) >> ${REDMINE_INSTALL_DIR}/Gemfile

## some gems complain about missing database.yml, shut them up!
exec_as_redmine cp ${REDMINE_INSTALL_DIR}/config/database.yml.example ${REDMINE_INSTALL_DIR}/config/database.yml

# install gems
cd ${REDMINE_INSTALL_DIR}

## use local cache if available
if [[ -d ${GEM_CACHE_DIR} ]]; then
  cp -a ${GEM_CACHE_DIR} ${REDMINE_INSTALL_DIR}/vendor/cache
  chown -R ${REDMINE_USER}: ${REDMINE_INSTALL_DIR}/vendor/cache
fi
exec_as_redmine bundle install -j$(nproc) --without development test --path ${REDMINE_INSTALL_DIR}/vendor/bundle

# finalize redmine installation
exec_as_redmine mkdir -p ${REDMINE_INSTALL_DIR}/tmp ${REDMINE_INSTALL_DIR}/tmp/pdf ${REDMINE_INSTALL_DIR}/tmp/pids ${REDMINE_INSTALL_DIR}/tmp/sockets

# create link public/plugin_assets directory
rm -rf ${REDMINE_INSTALL_DIR}/public/plugin_assets
exec_as_redmine ln -sf ${REDMINE_DATA_DIR}/tmp/plugin_assets ${REDMINE_INSTALL_DIR}/public/plugin_assets

# create link tmp/thumbnails directory
rm -rf ${REDMINE_INSTALL_DIR}/tmp/thumbnails
exec_as_redmine ln -sf ${REDMINE_DATA_DIR}/tmp/thumbnails ${REDMINE_INSTALL_DIR}/tmp/thumbnails

# symlink log -> ${REDMINE_LOG_DIR}/redmine
rm -rf ${REDMINE_INSTALL_DIR}/log
exec_as_redmine ln -sf ${REDMINE_LOG_DIR}/redmine ${REDMINE_INSTALL_DIR}/log

mkdir ${REDMINE_LOG_DIR}/
mkdir ${REDMINE_LOG_DIR}/supervisor
mkdir ${REDMINE_LOG_DIR}/nginx
chmod -R 777 ${REDMINE_LOG_DIR}

# disable default nginx configuration
rm -f /etc/nginx/sites-enabled/default

# run nginx as ${REDMINE_USER} user
sed -i "s|user www-data|user ${REDMINE_USER}|" /etc/nginx/nginx.conf

# move supervisord.log file to ${REDMINE_LOG_DIR}/supervisor/
sed -i "s|^logfile=.*|logfile=${REDMINE_LOG_DIR}/supervisor/supervisord.log ;|" /etc/supervisor/supervisord.conf

# move nginx logs to ${REDMINE_LOG_DIR}/nginx
sed -i \
  -e "s|access_log /var/log/nginx/access.log;|access_log ${REDMINE_LOG_DIR}/nginx/access.log;|" \
  -e "s|error_log /var/log/nginx/error.log;|error_log ${REDMINE_LOG_DIR}/nginx/error.log;|" \
  /etc/nginx/nginx.conf

# setup log rotation for redmine application logs
cat > /etc/logrotate.d/redmine <<EOF
${REDMINE_LOG_DIR}/redmine/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# setup log rotation for redmine vhost logs
cat > /etc/logrotate.d/redmine-vhost <<EOF
${REDMINE_LOG_DIR}/nginx/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

cat > /home/redmine/redmine/config/unicorn.rb <<EOF
# Sample verbose configuration file for Unicorn (not Rack)
#
# This configuration file documents many features of Unicorn
# that may not be needed for some applications. See
# http://unicorn.bogomips.org/examples/unicorn.conf.minimal.rb
# for a much simpler configuration file.
#
# See http://unicorn.bogomips.org/Unicorn/Configurator.html for complete
# documentation.

# Uncomment and customize the last line to run in a non-root path

# Use at least one worker per core if you're on a dedicated server,
# more will usually help for _short_ waits on databases/caches.
worker_processes 2

# Since Unicorn is never exposed to outside clients, it does not need to
# run on the standard HTTP port (80), there is no reason to start Unicorn
# as root unless it's from system init scripts.
# If running the master process as root and the workers as an unprivileged
# user, do this to switch euid/egid in the workers (also chowns logs):
user "redmine", "redmine"

# Help ensure your application will always spawn in the symlinked
# "current" directory that Capistrano sets up.
working_directory "/home/redmine/redmine" # available in 0.94.0+

# listen on both a Unix domain socket and a TCP port,
# we use a shorter backlog for quicker failover when busy
listen "/home/redmine/redmine/tmp/sockets/redmine.socket", :backlog => 64
listen "127.0.0.1:8080", :tcp_nopush => true

# nuke workers after 30 seconds instead of 60 seconds (the default)
timeout 60

# feel free to point this anywhere accessible on the filesystem
pid "/home/redmine/redmine/tmp/pids/unicorn.pid"

# By default, the Unicorn logger will write to stderr.
# Additionally, some applications/frameworks log to stderr or stdout,
# so prevent them from going to /dev/null when daemonized here:
stderr_path "/var/log/redmine/unicorn.stderr.log"
stdout_path "/var/log/redmine/unicorn.stdout.log"

# combine Ruby 2.0.0dev or REE with "preload_app true" for memory savings
# http://rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
preload_app true
GC.respond_to?(:copy_on_write_friendly=) and
GC.copy_on_write_friendly = true

# Enable this flag to have unicorn test client connections by writing the
# beginning of the HTTP headers before calling the application.  This
# prevents calling the application for connections that have disconnected
# while queued.  This is only guaranteed to detect clients on the same
# host unicorn runs on, and unlikely to detect disconnects even on a
# fast LAN.
check_client_connection false

before_fork do |server, worker|
# the following is highly recomended for Rails + "preload_app true"
# as there's no need for the master process to hold a connection
 defined?(ActiveRecord::Base) and
     ActiveRecord::Base.connection.disconnect!

# The following is only recommended for memory/DB-constrained
# installations.  It is not needed if your system can house
# twice as many worker_processes as you have configured.
#
# This allows a new master process to incrementally
# phase out the old master process with SIGTTOU to avoid a
# thundering herd (especially in the "preload_app false" case)
# when doing a transparent upgrade.  The last worker spawned
# will then kill off the old master process with a SIGQUIT.
  old_pid = "#{server.config[:pid]}.oldbin"
  if old_pid != server.pid
    begin
      sig = (worker.nr + 1) >= server.worker_processes ? :QUIT : :TTOU
      Process.kill(sig, File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
    end
  end
#
# Throttle the master from forking too quickly by sleeping.  Due
# to the implementation of standard Unix signal handlers, this
# helps (but does not completely) prevent identical, repeated signals
# from being lost when the receiving process is busy.
# sleep 1
end

after_fork do |server, worker|
  # per-process listener ports for debugging/admin/migrations
  # addr = "127.0.0.1:#{9293 + worker.nr}"
  # server.listen(addr, :tries => -1, :delay => 5, :tcp_nopush => true)

  # the following is *required* for Rails + "preload_app true",
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.establish_connection

  worker.user('redmine', 'redmine') if Process.euid == 0

  # if preload_app is true, then you may also want to check and
  # restart any other shared sockets/descriptors such as Memcached,
  # and Redis.  TokyoCabinet file handles are safe to reuse
  # between any number of forked children (assuming your kernel
  # correctly implements pread()/pwrite() system calls)
end
EOF

# configure supervisord log rotation
cat > /etc/logrotate.d/supervisord <<EOF
${REDMINE_LOG_DIR}/supervisor/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure supervisord to start nginx
cat > /etc/supervisor/conf.d/nginx.conf <<EOF
[program:nginx]
priority=20
directory=/tmp
command=/usr/sbin/nginx -g "daemon off;"
user=root
autostart=true
autorestart=true
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start unicorn
cat > /etc/supervisor/conf.d/unicorn.conf <<EOF
[program:unicorn]
priority=10
directory=${REDMINE_INSTALL_DIR}
environment=HOME=${REDMINE_HOME}
command=bundle exec unicorn_rails -E ${RAILS_ENV} -c ${REDMINE_INSTALL_DIR}/config/unicorn.rb
user=${REDMINE_USER}
autostart=true
autorestart=true
stopsignal=QUIT
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start crond
cat > /etc/supervisor/conf.d/cron.conf <<EOF
[program:cron]
priority=20
directory=/tmp
command=/usr/sbin/cron -f
user=root
autostart=true
autorestart=true
stdout_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${REDMINE_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# purge build dependencies and cleanup apt
apt-get purge -y --auto-remove ${BUILD_DEPENDENCIES}
rm -rf /var/lib/apt/lists/*
