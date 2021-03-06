#!/usr/bin/env bash

source ${HOME}/variables.sh

SCENARIO=scenario003
SOURCE_SCHEMA="ssb"
SOURCE_TABLE="dwdate"
TARGET_SCHEMA="public"
TARGET_TABLE="${SOURCE_TABLE}"
PYTHON="python2"

DESCRIPTION="Perform Unload Copy with automatic password retrieval. "
DESCRIPTION="${DESCRIPTION}Use a Python generated key for unload/copy rather than KMS generated key. "
DESCRIPTION="${DESCRIPTION}Expect target location to be correct. "
DESCRIPTION="${DESCRIPTION}Use ${PYTHON}. "
DESCRIPTION="${DESCRIPTION}Should fail for environment without pycrypto. "

start_scenario "${DESCRIPTION}"

start_step "Create configuration JSON to copy ${SOURCE_SCHEMA}.${SOURCE_TABLE} of source cluster to ${TARGET_SCHEMA}.${TARGET_TABLE} on target cluster"

cat >${HOME}/${SCENARIO}.json <<EOF
{
  "unloadSource": {
    "clusterEndpoint": "${SourceClusterEndpointAddress}",
    "clusterPort": ${SourceClusterEndpointPort},
    "connectUser": "${SourceClusterMasterUsername}",
    "db": "${SourceClusterDBName}",
    "schemaName": "${SOURCE_SCHEMA}",
    "tableName": "${SOURCE_TABLE}"
  },
  "s3Staging": {
    "aws_iam_role": "${S3CopyRole}",
    "path": "s3://${CopyUnloadBucket}/${SCENARIO}/",
    "deleteOnSuccess": "True",
    "region": "eu-west-1",
    "kmsGeneratedKey": "False"
  },
  "copyTarget": {
    "clusterEndpoint": "${TargetClusterEndpointAddress}",
    "clusterPort": ${TargetClusterEndpointPort},
    "connectUser": "${SourceClusterMasterUsername}",
    "db": "${SourceClusterDBName}",
    "schemaName": "${TARGET_SCHEMA}",
    "tableName": "${TARGET_TABLE}"
  }
}
EOF

cat ${HOME}/${SCENARIO}.json >>${STDOUTPUT} 2>>${STDERROR}
r=$? && stop_step $r

start_step "Generate DDL for table ${SOURCE_SCHEMA}.${SOURCE_TABLE} on target cluster"
#Extract DDL
psql -h ${SourceClusterEndpointAddress} -p ${SourceClusterEndpointPort} -U ${SourceClusterMasterUsername} ${SourceClusterDBName} -c "select ddl from admin.v_generate_tbl_ddl where schemaname='${SOURCE_SCHEMA}' and tablename='${SOURCE_TABLE}';" | awk '/CREATE TABLE/{flag=1}/ ;$/{flag=0}flag' | sed "s/${SOURCE_SCHEMA}/${TARGET_SCHEMA}/" >${HOME}/${SCENARIO}.ddl.sql 2>>${STDERROR}
increment_step_result $?
cat ${HOME}/${SCENARIO}.ddl.sql >>${STDOUTPUT} 2>>${STDERROR}
increment_step_result $?
stop_step ${STEP_RESULT}

start_step "Drop table ${TARGET_SCHEMA}.${TARGET_TABLE} in target cluster if it exists"
psql -h ${TargetClusterEndpointAddress} -p ${TargetClusterEndpointPort} -U ${TargetClusterMasterUsername} ${TargetClusterDBName} -c "DROP TABLE IF EXISTS ${TARGET_SCHEMA}.${TARGET_TABLE};" 2>>${STDERROR} | grep "DROP TABLE"  >>${STDOUTPUT} 2>>${STDERROR}
r=$? && stop_step $r

start_step "Create table ${TARGET_SCHEMA}.${TARGET_TABLE} in target cluster"
psql -h ${TargetClusterEndpointAddress} -p ${TargetClusterEndpointPort} -U ${TargetClusterMasterUsername} ${TargetClusterDBName} -f ${HOME}/${SCENARIO}.ddl.sql | grep "CREATE TABLE"  >>${STDOUTPUT} 2>>${STDERROR}
r=$? && stop_step $r


start_step "Run Unload Copy Utility"
source ${VIRTUAL_ENV_PY27_DIR}/bin/activate >>${STDOUTPUT} 2>>${STDERROR}
cd ${HOME}/amazon-redshift-utils/src/UnloadCopyUtility && ${PYTHON} redshift_unload_copy.py --log-level debug ${HOME}/${SCENARIO}.json eu-west-1 >>${STDOUTPUT} 2>>${STDERROR}
EXPECTED_COUNT=`psql -h ${SourceClusterEndpointAddress} -p ${SourceClusterEndpointPort} -U ${SourceClusterMasterUsername} ${SourceClusterDBName} -c "select 'count='||count(*) from ${SOURCE_SCHEMA}.${SOURCE_TABLE};" | grep "count=[0-9]*"|awk -F= '{ print $2}'` >>${STDOUTPUT} 2>>${STDERROR}
psql -h ${TargetClusterEndpointAddress} -p ${TargetClusterEndpointPort} -U ${TargetClusterMasterUsername} ${TargetClusterDBName} -c "select 'count='||count(*) from ${TARGET_SCHEMA}.${TARGET_TABLE};" | grep "count=${EXPECTED_COUNT}" >>${STDOUTPUT} 2>>${STDERROR}
r=$?
if [ "$r" = "0" ]
then
  echo "Unload Copy Utility is expected to fail with return code one but return code was 0 in this case."
  echo "Change result to 2 to make sure the test failed."
  r=2
fi
if [ "$r" = "1" ]
then
  echo "Unload Copy Utility is expected to fail with return code one in this case."
  echo "Change result to 0 to make sure test passes."
  r=0
fi
stop_step $r
deactivate

stop_scenario