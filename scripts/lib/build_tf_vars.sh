#!/usr/bin/env bash
# Build the TF_VARS array from environment variables.
# Requires tfvars_defaults.sh to have been sourced first.

TF_VARS=(
    -var="aws_region=${AWS_REGION}"
    -var="pvc_cluster_tags={owner=\"${OWNER}\", environment=\"${ENVIRONMENT}\"}"

    -var="create_vpc=false"
    -var="vpc_name=${ENVIRONMENT}-cldr-vpc"
    -var="vpc_cidr_block=172.16.0.0/16"
    -var='azs=["ap-southeast-1a","ap-southeast-1b"]'
    -var='public_subnets_cidr=["172.16.0.0/24"]'
    -var='private_subnets_cidr=[]'
    -var="enable_nat_gateway=false"
    -var="enable_vpn_gateway=false"

    -var="create_new_sg=false"
    -var='allowed_cidrs=["137.83.231.109/32", "137.83.231.11/32", "208.127.31.110/32", "208.127.31.11/32", "139.180.248.227/32"]'
    -var='allowed_ports=[0]'
    -var="sg_name=${ENVIRONMENT}-pvc_cluster_sg"
    -var="existing_sg=${EXISTING_SG_NAME}"

    -var="create_eip=true"
    -var="cldr_eip_name=${ENVIRONMENT}-cldr-mngr-eip"

    -var="create_keypair=true"
    -var="keypair_name=${ENVIRONMENT}-pvc-new-keypair"
    -var="existing_keypair_name=${EXISTING_KEYPAIR_NAME}"

    -var='instance_groups={
      cldr_mngr = {
        count = '"${CLDR_MNGR_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${CLDR_MNGR_INSTANCE_TYPE}"'"
        volume_size = '"${CLDR_MNGR_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-cldr-mngr" }
      },
      ipa_server = {
        count = '"${IPA_SERVER_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${IPA_SERVER_INSTANCE_TYPE}"'"
        volume_size = '"${IPA_SERVER_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-ipa-server" }
      },
      pvcbase_master = {
        count = '"${PVCBASE_MASTER_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${PVCBASE_MASTER_INSTANCE_TYPE}"'"
        volume_size = '"${PVCBASE_MASTER_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-pvcbase-master" }
      },
      pvcbase_worker = {
        count = '"${PVCBASE_WORKER_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${PVCBASE_WORKER_INSTANCE_TYPE}"'"
        volume_size = '"${PVCBASE_WORKER_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-pvcbase-worker" }
      },
      pvcecs_master = {
        count = '"${PVCECS_MASTER_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${PVCECS_MASTER_INSTANCE_TYPE}"'"
        volume_size = '"${PVCECS_MASTER_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-pvcecs-master" }
      },
      pvcecs_worker = {
        count = '"${PVCECS_WORKER_COUNT}"'
        ami = "'"${AMI_ID}"'"
        instance_type = "'"${PVCECS_WORKER_INSTANCE_TYPE}"'"
        volume_size = '"${PVCECS_WORKER_VOLUME_SIZE}"'
        tags = { Name = "'"${ENVIRONMENT}"'-pvcecs-worker" }
      }
    }'
)
