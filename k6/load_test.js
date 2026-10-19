// Teste de estresse da API de Ingestão através do load balancer (Nginx).
// O comportamento realista dos caminhões fica com o simulador; aqui só importa a carga.
//
//   make k6                                    (dentro da rede do Compose, BASE_URL=http://nginx)
//   make k6 K6_VUS=500                         (pico menor, ex.: VM B2s)
//   k6 run -e BASE_URL=http://localhost k6/load_test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost';
const PICO_VUS = parseInt(__ENV.K6_VUS || '2000', 10);
// Pausa entre requisições de cada VU: 2.000 VUs x 1 req/s ≈ 2.000 req/s no pico.
const PAUSA_SEGUNDOS = parseFloat(__ENV.K6_SLEEP || '1');

export const options = {
  scenarios: {
    pico_brusco: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: PICO_VUS },  // 0 -> 2.000 VUs em 1 minuto
        { duration: '1m', target: PICO_VUS },  // sustenta o pico
        { duration: '30s', target: 0 },        // desaceleração
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<300'],  // latência p95 abaixo de 300 ms
    http_req_failed: ['rate<0.01'],    // taxa de erro abaixo de 1%
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// UUID v4 sem dependência externa (jslib exigiria acesso à internet no container).
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export default function () {
  // Payload válido e "neutro": velocidade abaixo de 80 km/h, dentro do geofence de São Paulo
  // e motor desligado, para não gerar alertas nem SENSOR_MORTO depois que o teste termina.
  const payload = JSON.stringify({
    id_evento: uuidv4(),
    id_veiculo: `K6-${__VU}`,
    sequencia: __ITER,
    timestamp: new Date().toISOString(),
    latitude: -23.5505 + (Math.random() - 0.5) * 0.2,
    longitude: -46.6333 + (Math.random() - 0.5) * 0.2,
    velocidade: Math.round(Math.random() * 79 * 10) / 10,
    motor_ligado: false,
  });

  const res = http.post(`${BASE_URL}/api/telemetry`, payload, {
    headers: { 'Content-Type': 'application/json', 'X-Correlation-ID': uuidv4() },
    tags: { name: 'POST /api/telemetry' },
    timeout: '15s',
  });

  check(res, { 'status 202 (confirmado pelo broker)': (r) => r.status === 202 });
  sleep(PAUSA_SEGUNDOS);
}
