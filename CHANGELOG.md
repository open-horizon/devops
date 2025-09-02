# Changelog

All notable changes to this project will be documented in this file.

## [] - 2025-09-02
- Added support for MongoDB v6.x via environment variable toggle.
    - Due to licensing changes after version 4 this will be disabled by default.
    - Users should evaluate MongoDb's software licensing terms before enabling at their own risk.
- Fixed Arm64 version reference for Open Horizon's OpenBao plugin.
- Updated the default version of the plugin pulled.
- The script will no longer automatically overwrite all of your local files with copies from this repository.
- Bug fixes.

## [] - 2025-05-07
- Update the test-fdo.sh script to use the new FDO Rendezvous server.

## [] - 2025-03-12
- Issue-200: Removed erroneous double-quotes from Exchange's TLS configuration variables.

## [] - 2024-10-31
- Issue-186: Removed erroneous lines from agbot-tmpl.json.

## [] - 2024-10-28
- Removed auth method trust from PostgreSQL containers.
- Added user passwords to PostgreSQL containers.
- Added scram_sha_256 cryptographic hashing to PostgreSQL containers for user passwords.

## [] - 2024-04-11
- Issue: 167: Changes Vault references to OpenBao.

## [] - 2024-01-16
- Issue 156: Updated FDO components to version 1.1.7

## [] - 2023-11-13
- Issue 152: Updated FDO components to version 1.1.6
- Fixed package name typo in Fedora.
- Changed docker-compose download to pull the minimum allowed version.

## [] - 2023-07-10
- Issue 146: Integrated FDO into all-in-1.
- Removed SDO Support.
- Added initial Fedora support.
- Added CHANGELOG.md
- Added MAINTAINERS.md
