-- ---------------------------------------------------------------------------
-- psa sema alt kumesi - plesk_clone.sh'in sorguladigi tablolar
-- Gercek Plesk Obsidian 18.x kolon adlariyla birebir.
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS psa DEFAULT CHARSET utf8mb4;
USE psa;

CREATE TABLE IF NOT EXISTS clients (
  id INT AUTO_INCREMENT PRIMARY KEY,
  login VARCHAR(255) UNIQUE,
  type VARCHAR(32) DEFAULT 'admin'
);

-- Gercek Plesk'te servis planlari "Templates" tablosundadir; domain ile bagi
-- Subscriptions + PlansSubscriptions uzerinden kurulur. "ServicePlans" ve
-- "domains.plan_id" gercek semada YOKTUR.
CREATE TABLE IF NOT EXISTS Templates (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255),
  owner_id INT DEFAULT 1,
  type VARCHAR(32) DEFAULT 'domain',
  uuid VARCHAR(64),
  UNIQUE KEY name_type (name, type)
);

CREATE TABLE IF NOT EXISTS Subscriptions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  object_id INT,
  object_type VARCHAR(32) DEFAULT 'domain',
  uuid VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS PlansSubscriptions (
  subscription_id INT,
  plan_id INT,
  quantity INT DEFAULT 1
);

CREATE TABLE IF NOT EXISTS IP_Addresses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ip_address VARCHAR(64) UNIQUE
);

CREATE TABLE IF NOT EXISTS accounts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  type VARCHAR(32) DEFAULT 'plain',
  password VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS sys_users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  login VARCHAR(255) UNIQUE,
  account_id INT,
  home VARCHAR(255),
  shell VARCHAR(255) DEFAULT '/bin/false',
  quota BIGINT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS dns_zone (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS domains (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) UNIQUE,
  cl_id INT,
  dns_zone_id INT,
  certificate_id INT NULL,
  guid VARCHAR(64),
  parentDomainId INT DEFAULT 0,
  webspace_id INT DEFAULT 0,
  status INT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS hosting (
  dom_id INT PRIMARY KEY,
  sys_user_id INT,
  www_root VARCHAR(255) DEFAULT 'httpdocs',
  php_handler_id VARCHAR(64)
);

-- Gercek Plesk handler listesini dosyalardan uretir; burada CLI ciktisini
-- besleyen simulator-ici bir tablodur.
CREATE TABLE IF NOT EXISTS php_handlers (
  id VARCHAR(64) PRIMARY KEY,
  version VARCHAR(16),
  custom_version VARCHAR(16),
  display_name VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS data_bases (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255),
  dom_id INT,
  type VARCHAR(32) DEFAULT 'mysql',
  db_server_id INT DEFAULT 1
);

CREATE TABLE IF NOT EXISTS db_users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  login VARCHAR(255),
  db_id INT,
  account_id INT
);

CREATE TABLE IF NOT EXISTS domain_aliases (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255),
  dom_id INT
);

CREATE TABLE IF NOT EXISTS mail (
  id INT AUTO_INCREMENT PRIMARY KEY,
  mail_name VARCHAR(255),
  dom_id INT,
  account_id INT
);

CREATE TABLE IF NOT EXISTS dns_recs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  dns_zone_id INT,
  type VARCHAR(16),
  host VARCHAR(255),
  val VARCHAR(512),
  opt VARCHAR(64),
  displayHost VARCHAR(255),
  displayVal VARCHAR(512)
);

CREATE TABLE IF NOT EXISTS disk_usage (
  dom_id INT PRIMARY KEY,
  httpdocs BIGINT DEFAULT 0, httpsdocs BIGINT DEFAULT 0, subdomains BIGINT DEFAULT 0,
  web_users BIGINT DEFAULT 0, anonftp BIGINT DEFAULT 0, logs BIGINT DEFAULT 0,
  mysql_dbases BIGINT DEFAULT 0, mssql_dbases BIGINT DEFAULT 0, mailboxes BIGINT DEFAULT 0,
  maillists BIGINT DEFAULT 0, domaindumps BIGINT DEFAULT 0, www_root BIGINT DEFAULT 0,
  dbases BIGINT DEFAULT 0, configs BIGINT DEFAULT 0, chroot BIGINT DEFAULT 0,
  pgsql_dbases BIGINT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS certificates (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) UNIQUE,
  cert TEXT, pvt TEXT, ca TEXT
);

CREATE TABLE IF NOT EXISTS dom_param (
  id INT AUTO_INCREMENT PRIMARY KEY,
  dom_id INT,
  param VARCHAR(128),
  val TEXT
);

CREATE TABLE IF NOT EXISTS DomainServices (
  id INT AUTO_INCREMENT PRIMARY KEY,
  dom_id INT,
  ipCollectionId INT,
  type VARCHAR(32) DEFAULT 'web'
);

CREATE TABLE IF NOT EXISTS IpAddressesCollections (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ipCollectionId INT,
  ipAddressId INT
);

-- ---- baslangic verisi ----
INSERT IGNORE INTO clients (id, login, type) VALUES (1, 'admin', 'admin');
INSERT IGNORE INTO Templates (id, name, type) VALUES
  (1, 'Default Domain', 'domain'), (2, 'Unlimited', 'domain'), (3, 'Default Reseller', 'reseller');
INSERT IGNORE INTO php_handlers (id, version, custom_version, display_name) VALUES
  ('plesk-php82-fpm', '8.2', '0', 'PHP 8.2.0 FPM'),
  ('plesk-php83-fpm', '8.3', '0', 'PHP 8.3.0 FPM'),
  ('plesk-php74-fpm', '7.4', '33', 'PHP 7.4.33 FPM');
