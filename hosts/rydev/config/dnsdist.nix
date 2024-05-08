-- disable security status polling via DNS
setSecurityPollSuffix("")

-- Local Bind
newServer({
  address = "127.0.0.1:5391",
  pool = "bind",
  healthCheckMode="lazy",
  checkInterval=1,
  lazyHealthCheckFailedInterval=30,
  rise=2,
  maxCheckFailures=3,
  lazyHealthCheckThreshold=30,
  lazyHealthCheckSampleSize=100,
  lazyHealthCheckMinSampleCount=10,
  lazyHealthCheckMode='TimeoutOnly',
  useClientSubnet = true
})

-- Local Blocky
newServer({
  address = "127.0.0.1:5390",
  pool = "adguard",
  checkName = "adguard.holthome.net",
  healthCheckMode = "lazy",
  checkInterval = 1800,
  maxCheckFailures = 3,
  lazyHealthCheckFailedInterval = 30,
  rise = 2,
  lazyHealthCheckThreshold = 30,
  lazyHealthCheckSampleSize = 100,
  lazyHealthCheckMinSampleCount = 10,
  lazyHealthCheckMode = 'TimeoutOnly',
  useClientSubnet = true
})

-- Adguard will be given requester IP
setECSSourcePrefixV4(32)

-- CloudFlare DNS over DoH
newServer({
  address = "1.1.1.1:443",
  tls = "openssl",
  dohPath="/dns-query",
  subjectName = "cloudflare-dns.com",
  validateCertificates = true,
  checkInterval = 10,
  checkTimeout = 2000,
  pool = "cloudflare_general"
})
newServer({
  address = "1.1.1.3:443",
  tls = "openssl",
  dohPath="/dns-query",
  subjectName = "cloudflare-dns.com",
  validateCertificates = true,
  checkInterval = 10,
  checkTimeout = 2000,
  pool = "cloudflare_kids"
})

-- Enable caching
pc = newPacketCache(10000, {
  maxTTL = 86400,
  minTTL = 0,
  temporaryFailureTTL = 60,
  staleTTL = 60,
  dontAge = false
})
getPool(""):setCache(pc)

-- Request logging, uncomment to log DNS requests/responses to stdout
-- addAction(AllRule(), LogAction("", false, false, true, false, false))
-- addResponseAction(AllRule(), LogResponseAction("", false, true, false, false))

-- Routing rules
addAction("10.35.0.0/16", PoolAction("cloudflare_general"))     -- guest vlan
addAction("10.35.0.0/16", DropAction())                        -- stop processing

addAction("10.50.0.0/16", PoolAction("cloudflare_general"))     -- video vlan
addAction("10.50.0.0/16", DropAction())                        -- stop processing

addAction('unifi', PoolAction('bind'))
addAction('holthome.net', PoolAction('bind'))
addAction('10.in-addr.arpa', PoolAction('bind'))

addAction("10.10.0.0/16", PoolAction("adguard"))  -- lan
addAction("10.9.18.0/24", PoolAction("cloudflare_general"))  -- mgmt
addAction("10.20.0.0/16", PoolAction("cloudflare_general"))  -- servers vlan
addAction("10.30.0.0/16", PoolAction("adguard"))  -- trusted vlan
addAction("10.40.0.0/16", PoolAction("cloudflare_general"))      -- iot vlan
addAction("10.11.0.0/16", PoolAction("adguard")) -- wg_trusted vlan
addAction("10.6.0.0/16", PoolAction("adguard")) -- services vlan