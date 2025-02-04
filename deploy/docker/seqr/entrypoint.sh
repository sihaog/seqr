#!/usr/bin/env bash

set -x

env

echo SHELL: $SHELL
echo PATH: $PATH
echo PYTHONPATH: $PYTHONPATH

# init gcloud
if [ "$GCLOUD_PROJECT" ]; then
    gcloud config set project "$GCLOUD_PROJECT"
fi

if [ "$GCLOUD_ZONE" ]; then
    gcloud config set compute/zone "$GCLOUD_ZONE"
fi

if [ -e "/.config/service-account-key.json" ]; then
    # authenticate to google cloud using service account
    cp /usr/share/zoneinfo/US/Eastern /etc/localtime
    gcloud auth activate-service-account --key-file /.config/service-account-key.json
    cp /.config/boto /root/.boto
fi

# link to persistent disk dir with static files
mkdir -p /seqr_static_files/generated_files

# launch django dev server in background
cd /seqr

if [ "$SEQR_GIT_BRANCH" ]; then
  git pull
  git checkout "$SEQR_GIT_BRANCH"
fi

pip install --upgrade -r requirements.txt  # doublecheck that requirements are up-to-date

# allow pg_dump and other postgres command-line tools to run without having to enter a password
echo "*:*:*:*:$POSTGRES_PASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass
cat ~/.pgpass

# init seqrdb unless it already exists
if ! psql --host "$POSTGRES_SERVICE_HOSTNAME" -U postgres -l | grep seqrdb; then

  psql --host "$POSTGRES_SERVICE_HOSTNAME" -U postgres -c 'CREATE DATABASE reference_data_db';
  psql --host "$POSTGRES_SERVICE_HOSTNAME" -U postgres -c 'CREATE DATABASE seqrdb';
  python -u manage.py makemigrations
  python -u manage.py migrate
  python -u manage.py migrate --database=reference_data
  python -u manage.py check
  python -u manage.py collectstatic --no-input
  python -u manage.py loaddata variant_tag_types
  python -u manage.py loaddata variant_searches
  python -u manage.py update_all_reference_data --use-cached-omim
fi

# launch django server in background
/usr/local/bin/start_server.sh

if [ "$RUN_CRON_JOBS" ]; then
    # set up cron jobs
    echo 'SHELL=/bin/bash
0 0 * * 0 /usr/local/bin/python /seqr/manage.py run_settings_backup --bucket $DATABASE_BACKUP_BUCKET --deployment-type $DEPLOYMENT_TYPE >> /proc/1/fd/1 2>&1
0 0 * * 0 /usr/local/bin/python /seqr/manage.py update_omim --omim-key $OMIM_KEY >> /proc/1/fd/1 2>&1
0 0 * * 0 /usr/local/bin/python /seqr/manage.py update_human_phenotype_ontology >> /proc/1/fd/1 2>&1
0 0 * * 0 /usr/local/bin/python /seqr/manage.py import_all_panels https://panelapp.agha.umccr.org/api/v1 --label=AU >> /proc/1/fd/1 2>&1
0 0 * * 0 /usr/local/bin/python /seqr/manage.py import_all_panels https://panelapp.genomicsengland.co.uk/api/v1 --label=UK >> /proc/1/fd/1 2>&1
0 12 * * 1 /usr/local/bin/python /seqr/manage.py detect_inactive_privileged_users >> /proc/1/fd/1 2>&1
0 2 * * * /usr/local/bin/python /seqr/manage.py check_bam_cram_paths >> /proc/1/fd/1 2>&1
' | crontab -

    env > /etc/environment  # this is necessary for crontab commands to run with the right env. vars.

    /etc/init.d/cron start
fi


# sleep to keep image running even if gunicorn is killed / restarted
sleep 1000000000000
