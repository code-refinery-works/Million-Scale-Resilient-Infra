#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { ScalableStack } from "../lib/stack";

const app = new cdk.App();

new ScalableStack(app, "ScalableStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region:  process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  appImage:           app.node.tryGetContext("appImage")           ?? "nginx:latest",
  acmCertArn:         app.node.tryGetContext("acmCertArn")         ?? "",
  originVerifyToken:  app.node.tryGetContext("originVerifyToken")  ?? "change-me-secret",
});