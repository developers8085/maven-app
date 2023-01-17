#!/usr/bin/env bash

# Copyright 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

# DO NOT put "" around --parameter-overrides argument this will cause failures since it is expecting Key1=Value1 Key2=Value2 format
# To execute multiple parameters use a comma delimiter, example "pProduct=goose-image,pIamEcsTaskDefArn=goose-image-task-def"

# Definitions
function deploy_stack () {
  local _STACK=$1
  local _TEMPLATE=$2
  local _PARAMETERS=$3

  echo "Creating CloudFormation Stack:${_STACK} using Parameters:${_PARAMETERS}"
  aws cloudformation deploy \
    --template-file "${_TEMPLATE}" \
    --stack-name "${_STACK}" \
    --parameter-overrides $(echo "${_PARAMETERS}" | sed 's/|/ /g') \
    --no-fail-on-empty-changeset \
    --capabilities CAPABILITY_NAMED_IAM \
    --role-arn "${CFN_ROLE_ARN}" \
    --tags \
      uai=${UAI} \
      env=${ENVIRONMENT} \
      createdBy=${CREATED_BY} \
      Name=${_STACK}
}

# Ensure variables were passed correctly
echo "Uai:${UAI}"
echo "Environment:${ENVIRONMENT}"
echo "Application Name:${APP_NAME}"
echo "createdBy:${CREATED_BY}"
echo "Prefix:${PLATFORM_PREFIX}"

echo "VPC ID:${VPC_ID}"
echo "Subnet-1:${SUBNET_1}"
echo "Subnet-2:${SUBNET_2}"

echo "Container Name:${CONTAINER_NAME}"
echo "Log Level:${LOG_LEVEL}"
echo "App Route:${APP_ROUTE}"
echo "Server Name:${SERVER_NAME}"
echo "App Context:${APP_CONTEXT}"
echo "Cert Arn:${CERT_ARN}"

echo "CodeBuild Role Arn:${CODE_BUILD_ROLE_ARN}"
echo "ECS Role Arn:${ECS_ROLE_ARN}"
echo "App Team Role Arn:${TEAM_ROLE_ARN}"
echo "CloudFormation Role Arn:${CFN_ROLE_ARN}"


STACK_EXIST=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE --query 'StackSummaries[?StackName==`'$(echo ${PLATFORM_PREFIX}-${APP_NAME})'-kms`].StackName' --output text 2> /dev/null)

if [ -z "${STACK_EXIST}" ]; then
# Deploy KMS
    _PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pIamRoles=${CODE_BUILD_ROLE_ARN},${ECS_ROLE_ARN},${TEAM_ROLE_ARN},${CFN_ROLE_ARN}|pPendingWindowInDays=7"
    deploy_stack \
    ${PLATFORM_PREFIX}-${APP_NAME}-kms \
    iac/cloudformation/cf-kms.yaml \
    ${_PARAMS}
else
    echo "Stack (${PLATFORM_PREFIX}-${APP_NAME}-kms) already exists"
fi

KMS_ID=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-kms" --query 'Stacks[*].Outputs[?OutputKey==`oKmsId`].OutputValue' --output text)
echo "KMS ID: " ${KMS_ID}

# Deploy Secrets
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pKmsKey=${KMS_ID}|pArtifactoryUser=502827722|pLogLevel=${LOG_LEVEL}|pAppRoute=${APP_ROUTE}|pServerName=${SERVER_NAME}|pAppContext=${APP_CONTEXT}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-secrets \
  iac/cloudformation/cf-secrets.yaml \
  ${_PARAMS}

ARTIFACTORY_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-secrets" --query 'Stacks[*].Outputs[?OutputKey==`oArtifactorySecretArn`].OutputValue' --output text)
GITHUB_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-secrets" --query 'Stacks[*].Outputs[?OutputKey==`oGithubSecretArn`].OutputValue' --output text)
WEB_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-secrets" --query 'Stacks[*].Outputs[?OutputKey==`oWebSecretArn`].OutputValue' --output text)
APP_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-secrets" --query 'Stacks[*].Outputs[?OutputKey==`oAppSecretArn`].OutputValue' --output text)

# Deploy Security Group for ALB
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pKmsKey=${KMS_ID}|pVpcId=${VPC_ID}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-alb-sg \
  iac/cloudformation/cf-alb-sg.yaml \
  ${_PARAMS}

ALB_SG_ID=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-alb-sg" --query 'Stacks[*].Outputs[?OutputKey==`oSecurityGroupId`].OutputValue' --output text)

# Deploy Security Group for application fargate container
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pKmsKey=${KMS_ID}|pVpcId=${VPC_ID}|pAlbSecurityGroup=${ALB_SG_ID}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-app-sg \
  iac/cloudformation/cf-app-sg.yaml \
  ${_PARAMS}

APP_SG_ID=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-app-sg" --query 'Stacks[*].Outputs[?OutputKey==`oSecurityGroupId`].OutputValue' --output text)

# Deploy CodeBuild for application
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pKmsKey=${KMS_ID}|pVpcId=${VPC_ID}|pSubnet1=${SUBNET_1}|pSubnet2=${SUBNET_2}|pSecurityGroup=${ALB_SG_ID}|pCodeBuildIamRole=${CODE_BUILD_ROLE_ARN}|pArtifactoryArn=${ARTIFACTORY_SECRET_ARN}|pGithubArn=${GITHUB_SECRET_ARN}|pContainerName=${CONTAINER_NAME}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-codebuild-app \
  iac/cloudformation/cf-codebuild.yaml \
  ${_PARAMS}

# Deploy ALB
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pVpcId=${VPC_ID}|pALBListenerPort=443|pALBListenerProtocol=HTTPS|pTGListenerPort=8000|pTGListenerProtocol=HTTP|pSubnet1=${SUBNET_1}|pSubnet2=${SUBNET_2}|pAppSecurityGroupIds=${ALB_SG_ID}|pHealthCheckPath=/|pHealthCheckProtocol=HTTP|pCertificateArn=${CERT_ARN}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-alb \
  iac/cloudformation/cf-alb.yaml \
  ${_PARAMS}

TARGET_GROUP_ARN=$(aws cloudformation describe-stacks --stack-name "${PLATFORM_PREFIX}-${APP_NAME}-alb" --query 'Stacks[*].Outputs[?OutputKey==`oAlbTargetGroupArn`].OutputValue' --output text)

# Deploy ECS Cluster
_PARAMS="pApplicationName=${APP_NAME}|pEnv=${ENVIRONMENT}|pKmsKey=${KMS_ID}|pSubnet1=${SUBNET_1}|pSubnet2=${SUBNET_2}|pSecurityGroup=${APP_SG_ID}|pEcsIAMRole=${ECS_ROLE_ARN}|pTargetGroupArn=${TARGET_GROUP_ARN}|pArtifactoryArn=${ARTIFACTORY_SECRET_ARN}|pWebSecretArn=${WEB_SECRET_ARN}|pAppSecretArn=${APP_SECRET_ARN}|pContainerName=${CONTAINER_NAME}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-ecs-components \
  iac/cloudformation/cf-ecs-fargate.yaml \
  ${_PARAMS}

# Deploy Subscritpion to cloudwatch logs to ACTR central solution 
LogGroupName="/aws/ecs/${PLATFORM_PREFIX}-${APP_NAME}-${ENVIRONMENT}-ecs"
stackName="${PLATFORM_PREFIX}-${APP_NAME}-${ENVIRONMENT}-cmmc"
_PARAMS="LogGroupName=${LogGroupName}|RoleArn=${CFN_ROLE_ARN}|uai=${UAI}|ApplicationName=${APP_NAME}|createdBy=212774180|env=${ENVIRONMENT}|stackName=${stackName}"
deploy_stack \
  ${PLATFORM_PREFIX}-${APP_NAME}-actr-central-logging-subscription \
  iac/cloudformation/cf-actr-central-logging-subscription.yaml \
  ${_PARAMS}
