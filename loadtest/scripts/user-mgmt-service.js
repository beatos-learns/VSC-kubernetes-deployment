// k6 load test for the user-mgmt-service (Aufgabe 2, Chaos Testing).
//
// Path under test: the environment's public host -> DO load balancer ->
// Traefik -> frontend /api proxy -> backend Service -> backend replicas -> db.
// Every iteration is one user session: log in (bcrypt on the backend - the CPU
// work the HPA scales on) and read the own profile with the session cookie.
//
// Inputs (environment of the Job, loadtest/job.yaml):
//   TARGET_URL           https://auth-staging.<lb-ip>.nip.io  (required)
//   PEAK_VUS             virtual users at the plateau          (default 5)
//   TEST_USER_EMAIL      account used for the logins           (Secret k6-test-user)
//   TEST_USER_PASSWORD
//
// Load profile: controlled ramp in steps, a plateau long enough for the HPA to
// react (metrics-server 15 s, HPA sync 15 s, scale-up stabilisation 0 s),
// then a ramp to zero so the scale-down (5 min stabilisation window) can be
// observed after the run.

import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const BASE_URL = (__ENV.TARGET_URL || '').replace(/\/+$/, '');
const EMAIL = __ENV.TEST_USER_EMAIL;
const PASSWORD = __ENV.TEST_USER_PASSWORD;
const PEAK = Number(__ENV.PEAK_VUS || 5);

if (!BASE_URL) throw new Error('TARGET_URL is required (https://auth-<env>.<lb-ip>.nip.io)');
if (!EMAIL || !PASSWORD) throw new Error('TEST_USER_EMAIL / TEST_USER_PASSWORD are required (Secret k6-test-user)');

const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export const options = {
  // Let's Encrypt STAGING issues the certificates (README: not browser-trusted).
  insecureSkipTLSVerify: true,
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: Math.max(1, Math.round(PEAK / 4)) },
        { duration: '2m', target: Math.max(1, Math.round(PEAK / 2)) },
        { duration: '2m', target: PEAK },
        { duration: '3m', target: PEAK }, // plateau: HPA must have scaled by now
        { duration: '1m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  // What "still available under load" means for this service. A breached
  // threshold ends the run with a non-zero exit code -> the Job shows Failed.
  thresholds: {
    http_req_failed: ['rate<0.05'], // < 5 % transport/HTTP errors (4xx/5xx)
    'http_req_duration{name:login}': ['p(95)<2000'], // staging alert threshold
    'http_req_duration{name:me}': ['p(95)<1000'],
    checks: ['rate>0.95'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// Once per run: make sure the test account exists and can log in. Signup is
// idempotent for our purpose - a 4xx here means "already registered".
export function setup() {
  // The frontend answers 503 while its own backend health check is red (up to
  // ~15 s after a backend restart): give the stack a minute to come around
  // before calling the run off.
  let signup;
  let login;
  for (let attempt = 1; attempt <= 12; attempt++) {
    signup = http.post(
      `${BASE_URL}/api/signup`,
      JSON.stringify({ firstName: 'k6', lastName: 'loadtest', email: EMAIL, password: PASSWORD }),
      Object.assign({ tags: { name: 'signup' } }, JSON_HEADERS),
    );
    login = http.post(
      `${BASE_URL}/api/login`,
      JSON.stringify({ email: EMAIL, password: PASSWORD }),
      Object.assign({ tags: { name: 'login' } }, JSON_HEADERS),
    );
    if (login.status === 200) break;
    console.warn(`setup: attempt ${attempt}: signup HTTP ${signup.status}, login HTTP ${login.status} - retrying in 5 s`);
    sleep(5);
  }
  if (login.status !== 200) {
    fail(`setup: login as ${EMAIL} failed with HTTP ${login.status} (signup answered HTTP ${signup.status})`);
  }
  console.log(`setup: ${EMAIL} ready (signup HTTP ${signup.status}, login HTTP ${login.status}); target ${BASE_URL}, peak ${PEAK} VUs`);
}

export default function () {
  // Each VU has its own cookie jar: /api/login sets the httpOnly `jwt` cookie
  // that /api/me needs - exactly what the browser does.
  const login = http.post(
    `${BASE_URL}/api/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    Object.assign({ tags: { name: 'login' } }, JSON_HEADERS),
  );
  check(login, {
    'login: HTTP 200': (r) => r.status === 200,
    'login: session cookie set': (r) => r.cookies.jwt !== undefined,
  });

  const me = http.get(`${BASE_URL}/api/me`, { tags: { name: 'me' } });
  check(me, {
    'me: HTTP 200': (r) => r.status === 200,
    'me: own profile': (r) => r.status === 200 && r.json('email') === EMAIL,
  });

  sleep(1); // think time: ~1 login/s per VU at the plateau
}
