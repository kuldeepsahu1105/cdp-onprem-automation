#!/usr/bin/env bash
# Build the TF_VARS array from environment variables.
# Requires tfvars_defaults.sh to have been sourced first.

TF_VARS=(
    -var="aws_region=${AWS_REGION}"
    -var="pvc_cluster_tags={owner=\"${OWNER}\", environment=\"${ENVIRONMENT}\"}"

    -var="create_vpc=${CREATE_VPC}"
    -var="vpc_name=${VPC_NAME}"
    -var="vpc_cidr_block=${VPC_CIDR_BLOCK}"
    -var="azs=${VPC_AZS}"
    -var="public_subnets_cidr=${VPC_PUBLIC_SUBNETS_CIDR}"
    -var="private_subnets_cidr=${VPC_PRIVATE_SUBNETS_CIDR}"
    -var="enable_nat_gateway=${ENABLE_NAT_GATEWAY}"
    -var="enable_vpn_gateway=${ENABLE_VPN_GATEWAY}"

    -var="create_new_sg=${CREATE_NEW_SG}"
    -var="allowed_cidrs=${ALLOWED_CIDRS}"
    -var="allowed_ports=${ALLOWED_PORTS}"
    -var="sg_name=${SG_NAME}"
    -var="existing_sg=${EXISTING_SG_NAME}"

    -var="create_eip=${CREATE_EIP}"
    -var="cldr_eip_name=${CLDR_EIP_NAME}"

    -var="create_keypair=${CREATE_KEYPAIR}"
    -var="keypair_name=${KEYPAIR_NAME}"
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
