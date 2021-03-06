# Install and start **Ceilometer** service in devstack
#
# To enable Ceilometer in devstack add an entry to local.conf that
# looks like
#
# [[local|localrc]]
# enable_plugin ceilometer git://git.openstack.org/openstack/ceilometer
#
# By default all ceilometer services are started (see devstack/settings)
# except for the ceilometer-aipmi service. To disable a specific service
# use the disable_service function.
#
# NOTE: Currently, there are two ways to get the IPMI based meters in
# OpenStack. One way is to configure Ironic conductor to report those meters
# for the nodes managed by Ironic and to have Ceilometer notification
# agent to collect them. Ironic by default does NOT enable that reporting
# functionality. So in order to do so, users need to set the option of
# conductor.send_sensor_data to true in the ironic.conf configuration file
# for the Ironic conductor service, and also enable the
# ceilometer-anotification service.
#
# The other way is to use Ceilometer ipmi agent only to get the IPMI based
# meters. To make use of the Ceilometer ipmi agent, it must be explicitly
# enabled with the following setting:
#
# enable_service ceilometer-aipmi
#
# To avoid duplicated meters, users need to make sure to set the
# option of conductor.send_sensor_data to false in the ironic.conf
# configuration file if the node on which Ceilometer ipmi agent is running
# is also managed by Ironic.
#
# Several variables set in the localrc section adjust common behaviors
# of Ceilometer (see within for additional settings):
#
#   CEILOMETER_PIPELINE_INTERVAL:  Seconds between pipeline processing runs. Default 600.
#   CEILOMETER_BACKEND:            Database backend (e.g. 'mysql', 'mongodb', 'gnocchi', 'none')
#   CEILOMETER_COORDINATION_URL:   URL for group membership service provided by tooz.
#   CEILOMETER_EVENT_ALARM:        Set to True to enable publisher for event alarming

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set -o xtrace

# Support potential entry-points console scripts in VENV or not
if [[ ${USE_VENV} = True ]]; then
    PROJECT_VENV["ceilometer"]=${CEILOMETER_DIR}.venv
    CEILOMETER_BIN_DIR=${PROJECT_VENV["ceilometer"]}/bin
else
    CEILOMETER_BIN_DIR=$(get_python_exec_prefix)
fi

# Test if any Ceilometer services are enabled
# is_ceilometer_enabled
function is_ceilometer_enabled {
    [[ ,${ENABLED_SERVICES} =~ ,"ceilometer-" ]] && return 0
    return 1
}

function ceilometer_service_url {
    echo "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT"
}


function gnocchi_service_url {
    echo "$GNOCCHI_SERVICE_PROTOCOL://$GNOCCHI_SERVICE_HOST/metric"
}

# _ceilometer_install_mongdb - Install mongodb and python lib.
function _ceilometer_install_mongodb {
    # Server package is the same on all
    local packages=mongodb-server

    if is_fedora; then
        # mongodb client
        packages="${packages} mongodb"
    fi

    install_package ${packages}

    if is_fedora; then
        restart_service mongod
    else
        restart_service mongodb
    fi

    # give time for service to restart
    sleep 5
}

# _ceilometer_install_redis() - Install the redis server and python lib.
function _ceilometer_install_redis {
    if is_ubuntu; then
        install_package redis-server
        restart_service redis-server
    else
        # This will fail (correctly) where a redis package is unavailable
        install_package redis
        restart_service redis
    fi

    pip_install_gr redis
}

# Configure mod_wsgi
function _ceilometer_config_apache_wsgi {
    sudo mkdir -p $CEILOMETER_WSGI_DIR

    local ceilometer_apache_conf=$(apache_site_config_for ceilometer)
    local apache_version=$(get_apache_version)
    local venv_path=""

    # Copy proxy vhost and wsgi file
    sudo cp $CEILOMETER_DIR/ceilometer/api/app.wsgi $CEILOMETER_WSGI_DIR/app

    if [[ ${USE_VENV} = True ]]; then
        venv_path="python-path=${PROJECT_VENV["ceilometer"]}/lib/$(python_version)/site-packages"
    fi

    sudo cp $CEILOMETER_DIR/devstack/apache-ceilometer.template $ceilometer_apache_conf
    sudo sed -e "
        s|%PORT%|$CEILOMETER_SERVICE_PORT|g;
        s|%APACHE_NAME%|$APACHE_NAME|g;
        s|%WSGIAPP%|$CEILOMETER_WSGI_DIR/app|g;
        s|%USER%|$STACK_USER|g;
        s|%VIRTUALENV%|$venv_path|g
    " -i $ceilometer_apache_conf
}

# Install required services for coordination
function _ceilometer_prepare_coordination {
    if echo $CEILOMETER_COORDINATION_URL | grep -q '^memcached:'; then
        install_package memcached
    elif [[ "${CEILOMETER_COORDINATOR_URL%%:*}" == "redis" || "${CEILOMETER_CACHE_BACKEND##*.}" == "redis" || "${CEILOMETER_BACKEND}" == "gnocchi" ]]; then
        _ceilometer_install_redis
    fi
}

# Install required services for storage backends
function _ceilometer_prepare_storage_backend {
    if [ "$CEILOMETER_BACKEND" = 'mongodb' ] ; then
        pip_install_gr pymongo
        _ceilometer_install_mongodb
    fi
}


# Install the python modules for inspecting nova virt instances
function _ceilometer_prepare_virt_drivers {
    # Only install virt drivers if we're running nova compute
    if is_service_enabled n-cpu ; then
        if [[ "$VIRT_DRIVER" = 'libvirt' ]]; then
            pip_install_gr libvirt-python
        fi

        if [[ "$VIRT_DRIVER" = 'vsphere' ]]; then
            pip_install_gr oslo.vmware
        fi
    fi
}


# Create ceilometer related accounts in Keystone
function ceilometer_create_accounts {
    # At this time, the /etc/openstack/clouds.yaml is available,
    # we could leverage that by setting OS_CLOUD
    OLD_OS_CLOUD=$OS_CLOUD
    export OS_CLOUD='devstack-admin'

    create_service_user "ceilometer" "admin"

    if is_service_enabled ceilometer-api; then
        get_or_create_service "ceilometer" "metering" "OpenStack Telemetry Service"
        get_or_create_endpoint "metering" \
            "$REGION_NAME" \
            "$(ceilometer_service_url)" \
            "$(ceilometer_service_url)" \
            "$(ceilometer_service_url)"
    fi

    if is_service_enabled swift; then
        # Ceilometer needs ResellerAdmin role to access Swift account stats.
        get_or_add_user_project_role "ResellerAdmin" "ceilometer" $SERVICE_PROJECT_NAME
    fi

    if ! [[ $DEVSTACK_PLUGINS =~ 'gnocchi' ]] && [ "$CEILOMETER_BACKEND" == "gnocchi" ]; then
        create_service_user "gnocchi"
        local gnocchi_service=$(get_or_create_service "gnocchi" \
            "metric" "OpenStack Metric Service")
        get_or_create_endpoint $gnocchi_service \
            "$REGION_NAME" \
            "$(gnocchi_service_url)" \
            "$(gnocchi_service_url)" \
            "$(gnocchi_service_url)"
    fi
    export OS_CLOUD=$OLD_OS_CLOUD
}


function install_gnocchi {
    echo_summary "Installing Gnocchi"
    if [ $GNOCCHI_GIT_PATH ]; then
        pip_install -e $GNOCCHI_GIT_PATH[redis,${DATABASE_TYPE},keystone] uwsgi
    else
        pip_install gnocchi[redis,${DATABASE_TYPE},keystone] uwsgi
    fi
    recreate_database gnocchi
    sudo install -d -o $STACK_USER -m 755 $GNOCCHI_CONF_DIR

    iniset $GNOCCHI_CONF DEFAULT debug "$ENABLE_DEBUG_LOG_LEVEL"
    iniset $GNOCCHI_CONF indexer url `database_connection_url gnocchi`
    iniset $GNOCCHI_CONF storage driver redis
    iniset $GNOCCHI_CONF storage redis_url redis://localhost:6379
    iniset $GNOCCHI_CONF metricd metric_processing_delay "$GNOCCHI_METRICD_PROCESSING_DELAY"

    iniset $GNOCCHI_CONF api auth_mode keystone
    configure_auth_token_middleware $GNOCCHI_CONF gnocchi $GNOCCHI_AUTH_CACHE_DIR

    sudo mkdir -p $GNOCCHI_AUTH_CACHE_DIR
    sudo chown $STACK_USER $GNOCCHI_AUTH_CACHE_DIR
    rm -f $GNOCCHI_AUTH_CACHE_DIR/*

    gnocchi-upgrade

    rm -f "$GNOCCHI_UWSGI_FILE"

    write_uwsgi_config "$GNOCCHI_UWSGI_FILE" "$CEILOMETER_BIN_DIR/gnocchi-api" "/metric"

    if [ -n "$GNOCCHI_COORDINATOR_URL" ]; then
        iniset $GNOCCHI_CONF storage coordination_url "$GNOCCHI_COORDINATOR_URL"
    fi
}

# Activities to do before ceilometer has been installed.
function preinstall_ceilometer {
    echo_summary "Preinstall not in virtualenv context. Skipping."
}

# Remove WSGI files, disable and remove Apache vhost file
function _ceilometer_cleanup_apache_wsgi {
    if is_service_enabled ceilometer-api && [ "$CEILOMETER_USE_MOD_WSGI" == "True" ]; then
        sudo rm -f "$CEILOMETER_WSGI_DIR"/*
        sudo rmdir "$CEILOMETER_WSGI_DIR"
        sudo rm -f $(apache_site_config_for ceilometer)
    fi
}

function _ceilometer_drop_database {
    if is_service_enabled ceilometer-api ; then
        if [ "$CEILOMETER_BACKEND" = 'mongodb' ] ; then
            mongo ceilometer --eval "db.dropDatabase();"
        fi
    fi
}

# cleanup_ceilometer() - Remove residual data files, anything left over
# from previous runs that a clean run would need to clean up
function cleanup_ceilometer {
    _ceilometer_cleanup_apache_wsgi
    _ceilometer_drop_database
    sudo rm -f "$CEILOMETER_CONF_DIR"/*
    sudo rmdir "$CEILOMETER_CONF_DIR"
}

# Set configuraiton for cache backend.
# NOTE(cdent): This currently only works for redis. Still working
# out how to express the other backends.
function _ceilometer_configure_cache_backend {
    iniset $CEILOMETER_CONF cache enabled True
    iniset $CEILOMETER_CONF cache backend $CEILOMETER_CACHE_BACKEND

    inidelete $CEILOMETER_CONF cache backend_argument
    iniadd $CEILOMETER_CONF cache backend_argument url:$CEILOMETER_CACHE_URL
    iniadd $CEILOMETER_CONF cache backend_argument distributed_lock:True
    if [[ "${CEILOMETER_CACHE_BACKEND##*.}" == "redis" ]]; then
        iniadd $CEILOMETER_CONF cache backend_argument db:0
        iniadd $CEILOMETER_CONF cache backend_argument redis_expiration_time:600
    fi
}


# Set configuration for storage backend.
function _ceilometer_configure_storage_backend {

    inidelete $CEILOMETER_CONF database metering_connection

    if [ "$CEILOMETER_BACKEND" = 'none' ] ; then
        # It's ok for the backend to be 'none', if panko is enabled. We do not
        # combine this condition with the outer if statement, so that the else
        # clause below is not executed.
        if ! is_service_enabled panko-api; then
            echo_summary "All Ceilometer backends seems disabled, set \$CEILOMETER_BACKEND to select one."
        fi
    elif [ "$CEILOMETER_BACKEND" = 'mysql' ] || [ "$CEILOMETER_BACKEND" = 'postgresql' ] ; then
        iniset $CEILOMETER_CONF database metering_connection $(database_connection_url ceilometer)
    elif [ "$CEILOMETER_BACKEND" = 'mongodb' ] ; then
        iniset $CEILOMETER_CONF database metering_connection mongodb://localhost:27017/ceilometer
    elif [ "$CEILOMETER_BACKEND" = 'gnocchi' ] ; then
        # NOTE(gordc): set batching to better handle recording on a slow machine
        iniset $CEILOMETER_CONF collector batch_size 50
        iniset $CEILOMETER_CONF collector batch_timeout 5
        iniset $CEILOMETER_CONF dispatcher_gnocchi archive_policy ${GNOCCHI_ARCHIVE_POLICY}
        if is_service_enabled swift && [[ "$GNOCCHI_STORAGE_BACKEND" = 'swift' ]] ; then
            iniset $CEILOMETER_CONF dispatcher_gnocchi filter_service_activity "True"
            iniset $CEILOMETER_CONF dispatcher_gnocchi filter_project "gnocchi_swift"
        else
            iniset $CEILOMETER_CONF dispatcher_gnocchi filter_service_activity "False"
        fi
    else
        die $LINENO "Unable to configure unknown CEILOMETER_BACKEND $CEILOMETER_BACKEND"
    fi

    if [ "$CEILOMETER_BACKEND" = 'mysql' ] || [ "$CEILOMETER_BACKEND" = 'postgresql' ] || [ "$CEILOMETER_BACKEND" = 'mongodb' ]; then
        sed -i 's/gnocchi:\/\//database:\/\//g' $CEILOMETER_CONF_DIR/event_pipeline.yaml $CEILOMETER_CONF_DIR/pipeline.yaml
    fi

    # configure panko
    if is_service_enabled panko-api; then
        if ! grep -q 'panko' $CEILOMETER_CONF_DIR/event_pipeline.yaml ; then
            echo '          - panko://' >> $CEILOMETER_CONF_DIR/event_pipeline.yaml
        fi
    fi

    _ceilometer_drop_database
}

# Configure Ceilometer
function configure_ceilometer {

    local conffile

    iniset_rpc_backend ceilometer $CEILOMETER_CONF

    iniset $CEILOMETER_CONF oslo_messaging_notifications topics "$CEILOMETER_NOTIFICATION_TOPICS"
    iniset $CEILOMETER_CONF DEFAULT debug "$ENABLE_DEBUG_LOG_LEVEL"

    if [[ -n "$CEILOMETER_COORDINATION_URL" ]]; then
        iniset $CEILOMETER_CONF coordination backend_url $CEILOMETER_COORDINATION_URL
        iniset $CEILOMETER_CONF notification workload_partitioning True
        iniset $CEILOMETER_CONF notification workers $API_WORKERS
        iniset $CEILOMETER_CONF notification pipeline_processing_queues $API_WORKERS
    fi

    if [[ -n "$CEILOMETER_CACHE_BACKEND" ]]; then
        _ceilometer_configure_cache_backend
    fi

    # Install the policy file and declarative configuration files to
    # the conf dir.
    # NOTE(cdent): Do not make this a glob as it will conflict
    # with rootwrap installation done elsewhere and also clobber
    # ceilometer.conf settings that have already been made.
    # Anyway, explicit is better than implicit.
    for conffile in policy.json api_paste.ini; do
        cp $CEILOMETER_DIR/etc/ceilometer/$conffile $CEILOMETER_CONF_DIR
    done
    cp $CEILOMETER_DIR/etc/ceilometer/polling_all.yaml $CEILOMETER_CONF_DIR/polling.yaml

    cp $CEILOMETER_DIR/ceilometer/pipeline/data/*.yaml $CEILOMETER_CONF_DIR

    if [ "$CEILOMETER_PIPELINE_INTERVAL" ]; then
        sed -i "s/interval:.*/interval: ${CEILOMETER_PIPELINE_INTERVAL}/" $CEILOMETER_CONF_DIR/polling.yaml
    fi
    if [ "$CEILOMETER_EVENT_ALARM" == "True" ]; then
        if ! grep -q '^ *- notifier://?topic=alarm.all$' $CEILOMETER_CONF_DIR/event_pipeline.yaml; then
            sed -i '/^ *publishers:$/,+1s|^\( *\)-.*$|\1- notifier://?topic=alarm.all\n&|' $CEILOMETER_CONF_DIR/event_pipeline.yaml
        fi
    fi

    # The compute and central agents need these credentials in order to
    # call out to other services' public APIs.
    iniset $CEILOMETER_CONF service_credentials auth_type password
    iniset $CEILOMETER_CONF service_credentials user_domain_id default
    iniset $CEILOMETER_CONF service_credentials project_domain_id default
    iniset $CEILOMETER_CONF service_credentials project_name $SERVICE_PROJECT_NAME
    iniset $CEILOMETER_CONF service_credentials username ceilometer
    iniset $CEILOMETER_CONF service_credentials password $SERVICE_PASSWORD
    iniset $CEILOMETER_CONF service_credentials region_name $REGION_NAME
    iniset $CEILOMETER_CONF service_credentials auth_url $KEYSTONE_SERVICE_URI

    configure_auth_token_middleware $CEILOMETER_CONF ceilometer $CEILOMETER_AUTH_CACHE_DIR

    # Configure storage
    if is_service_enabled ceilometer-api; then
        _ceilometer_configure_storage_backend
    fi

    if is_service_enabled ceilometer-collector; then
        iniset $CEILOMETER_CONF collector workers $API_WORKERS
    fi

    if [[ "$VIRT_DRIVER" = 'vsphere' ]]; then
        iniset $CEILOMETER_CONF DEFAULT hypervisor_inspector vsphere
        iniset $CEILOMETER_CONF vmware host_ip "$VMWAREAPI_IP"
        iniset $CEILOMETER_CONF vmware host_username "$VMWAREAPI_USER"
        iniset $CEILOMETER_CONF vmware host_password "$VMWAREAPI_PASSWORD"
    fi

    if is_service_enabled ceilometer-api && [ "$CEILOMETER_USE_MOD_WSGI" == "True" ]; then
        _ceilometer_config_apache_wsgi
    fi

    if is_service_enabled ceilometer-aipmi; then
        # Configure rootwrap for the ipmi agent
        configure_rootwrap ceilometer
    fi
}

# init_ceilometer() - Initialize etc.
function init_ceilometer {
    # Create cache dir
    sudo install -d -o $STACK_USER $CEILOMETER_AUTH_CACHE_DIR
    rm -f $CEILOMETER_AUTH_CACHE_DIR/*

    if is_service_enabled ceilometer-api; then
        if is_service_enabled mysql postgresql ; then
            if [ "$CEILOMETER_BACKEND" = 'mysql' ] || [ "$CEILOMETER_BACKEND" = 'postgresql' ] || [ "$CEILOMETER_BACKEND" = 'es' ] ; then
                recreate_database ceilometer
                $CEILOMETER_BIN_DIR/ceilometer-upgrade --skip-gnocchi-resource-types
            fi
        fi
    fi
}

# Install Ceilometer.
# The storage and coordination backends are installed here because the
# virtualenv context is active at this point and python drivers need to be
# installed. The context is not active during preinstall (when it would
# otherwise makes sense to do the backend services).
function install_ceilometer {
    if is_service_enabled ceilometer-acentral ceilometer-acompute ceilometer-anotification gnocchi-api gnocchi-metricd; then
        _ceilometer_prepare_coordination
    fi

    ! [[ $DEVSTACK_PLUGINS =~ 'gnocchi' ]] && [ "$CEILOMETER_BACKEND" = 'gnocchi' ] && install_gnocchi

    if is_service_enabled ceilometer-api; then
        _ceilometer_prepare_storage_backend
    fi

    if is_service_enabled ceilometer-acompute ; then
        _ceilometer_prepare_virt_drivers
    fi

    install_ceilometerclient

    case $CEILOMETER_BACKEND in
        mongodb) extra=mongo;;
        gnocchi) extra=gnocchi;;
        mysql) extra=mysql;;
        postgresql) extra=postgresql;;
    esac
    setup_develop $CEILOMETER_DIR $extra
    sudo install -d -o $STACK_USER -m 755 $CEILOMETER_CONF_DIR
}

# install_ceilometerclient() - Collect source and prepare
function install_ceilometerclient {
    if use_library_from_git "python-ceilometerclient"; then
        git_clone_by_name "python-ceilometerclient"
        setup_dev_lib "python-ceilometerclient"
        sudo install -D -m 0644 -o $STACK_USER {${GITDIR["python-ceilometerclient"]}/tools/,/etc/bash_completion.d/}ceilometer.bash_completion
    else
        pip_install_gr python-ceilometerclient
    fi
}

# start_ceilometer() - Start running processes, including screen
function start_ceilometer {

    if ! [[ $DEVSTACK_PLUGINS =~ 'gnocchi' ]] && [ "$CEILOMETER_BACKEND" = "gnocchi" ] ; then
        run_process gnocchi-api "$CEILOMETER_BIN_DIR/uwsgi --ini $GNOCCHI_UWSGI_FILE" ""
        run_process gnocchi-metricd "$CEILOMETER_BIN_DIR/gnocchi-metricd --config-file $GNOCCHI_CONF"
        wait_for_service 30 "$(gnocchi_service_url)"
        $CEILOMETER_BIN_DIR/ceilometer-upgrade --skip-metering-database
    fi

    run_process ceilometer-acentral "$CEILOMETER_BIN_DIR/ceilometer-polling --polling-namespaces central --config-file $CEILOMETER_CONF"
    run_process ceilometer-aipmi "$CEILOMETER_BIN_DIR/ceilometer-polling --polling-namespaces ipmi --config-file $CEILOMETER_CONF"

    if [[ "$CEILOMETER_USE_MOD_WSGI" == "False" ]]; then
        run_process ceilometer-api "$CEILOMETER_BIN_DIR/ceilometer-api --port $CEILOMETER_SERVICE_PORT"
    elif is_service_enabled ceilometer-api; then
        enable_apache_site ceilometer
        restart_apache_server
        tail_log ceilometer /var/log/$APACHE_NAME/ceilometer.log
        tail_log ceilometer-api /var/log/$APACHE_NAME/ceilometer_access.log
    fi

    # run the notification agent/collector after restarting apache as it needs
    # operational keystone if using gnocchi
    run_process ceilometer-anotification "$CEILOMETER_BIN_DIR/ceilometer-agent-notification --config-file $CEILOMETER_CONF"
    run_process ceilometer-collector "$CEILOMETER_BIN_DIR/ceilometer-collector --config-file $CEILOMETER_CONF"

    # Start the compute agent late to allow time for the collector to
    # fully wake up and connect to the message bus. See bug #1355809
    if [[ "$VIRT_DRIVER" = 'libvirt' ]]; then
        run_process ceilometer-acompute "$CEILOMETER_BIN_DIR/ceilometer-polling --polling-namespaces compute --config-file $CEILOMETER_CONF" $LIBVIRT_GROUP
    fi
    if [[ "$VIRT_DRIVER" = 'vsphere' ]]; then
        run_process ceilometer-acompute "$CEILOMETER_BIN_DIR/ceilometer-polling --polling-namespaces compute --config-file $CEILOMETER_CONF"
    fi
}

# stop_ceilometer() - Stop running processes
function stop_ceilometer {
    if is_service_enabled ceilometer-api ; then
        if [ "$CEILOMETER_USE_MOD_WSGI" == "True" ]; then
            disable_apache_site ceilometer
            restart_apache_server
        else
            stop_process ceilometer-api
        fi
    fi

    # Kill the ceilometer screen windows
    for serv in ceilometer-acompute ceilometer-acentral ceilometer-aipmi ceilometer-anotification ceilometer-collector; do
        stop_process $serv
    done
}

# This is the main for plugin.sh
if is_service_enabled ceilometer; then
    if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # Set up other services
        echo_summary "Configuring system services for Ceilometer"
        preinstall_ceilometer
    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        echo_summary "Installing Ceilometer"
        # Use stack_install_service here to account for virtualenv
        stack_install_service ceilometer
    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        echo_summary "Configuring Ceilometer"
        configure_ceilometer
        # Get ceilometer keystone settings in place
        ceilometer_create_accounts
    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        echo_summary "Initializing Ceilometer"
        # Tidy base for ceilometer
        init_ceilometer
        # Start the services
        start_ceilometer
    elif [[ "$1" == "stack" && "$2" == "test-config" ]]; then
        iniset $TEMPEST_CONFIG telemetry alarm_granularity $CEILOMETER_ALARM_GRANULARITY
    fi

    if [[ "$1" == "unstack" ]]; then
        echo_summary "Shutting Down Ceilometer"
        stop_ceilometer
    fi

    if [[ "$1" == "clean" ]]; then
        echo_summary "Cleaning Ceilometer"
        cleanup_ceilometer
    fi
fi

# Restore xtrace
$XTRACE
