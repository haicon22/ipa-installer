/**
 * Bộ giải mã embedded.mobileprovision (CMS / PKCS#7) & Chứng chỉ X.509 ASN.1 DER
 * - Trích xuất XML Plist được ký bên trong embedded.mobileprovision
 * - Phân loại chính xác loại Provisioning Profile (Personal/Dev, Ad-Hoc, Enterprise, App Store)
 * - Giải mã trực tiếp chứng chỉ X.509 DER trong DeveloperCertificates (Subject CN, OU/Team,
 *   Issuer, Serial Number, NotBefore, NotAfter, URL máy chủ OCSP của Apple)
 */
import { parseXmlPlist } from './plist.js';

const utf8Decoder = new TextDecoder('utf-8', { fatal: false });
const latin1Decoder = new TextDecoder('iso-8859-1');

const OID_MAP = {
  '2.5.4.3': 'CN',
  '2.5.4.6': 'C',
  '2.5.4.10': 'O',
  '2.5.4.11': 'OU',
  '0.9.2342.19200300.100.1.1': 'UID',
  '1.3.6.1.5.5.7.48.1': 'OCSP',
  '1.2.840.113549.1.1.11': 'SHA256withRSA',
  '1.2.840.113549.1.1.5': 'SHA1withRSA',
  '1.2.840.10045.4.3.2': 'ECDSAwithSHA256',
  '1.2.840.10045.4.3.3': 'ECDSAwithSHA384'
};

function decodeOid(bytes) {
  if (!bytes || bytes.length === 0) return '';
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let val = 0;
  for (let i = 1; i < bytes.length; i++) {
    val = val * 128 + (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      parts.push(val);
      val = 0;
    }
  }
  return parts.join('.');
}

function parseAsn1(bytes, offset = 0, end = bytes.length) {
  const nodes = [];
  let p = offset;
  while (p < end) {
    const tag = bytes[p++];
    if (p >= end) break;
    let len = bytes[p++];
    if ((len & 0x80) !== 0) {
      const count = len & 0x7f;
      if (count === 0 || count > 4 || p + count > end) break;
      len = 0;
      for (let i = 0; i < count; i++) {
        len = (len << 8) | bytes[p++];
      }
    }
    const contentStart = p;
    const contentEnd = Math.min(end, contentStart + len);
    const isConstructed = (tag & 0x20) !== 0;
    const node = {
      tag,
      content: bytes.subarray(contentStart, contentEnd),
      children: isConstructed ? parseAsn1(bytes, contentStart, contentEnd) : null
    };
    nodes.push(node);
    p = contentEnd;
  }
  return nodes;
}

function parseAsn1Time(node) {
  const str = latin1Decoder.decode(node.content).trim();
  if (node.tag === 0x17) {
    // UTCTime: YYMMDDHHMMSSZ
    const yy = parseInt(str.slice(0, 2), 10);
    const year = yy >= 50 ? 1900 + yy : 2000 + yy;
    const iso = `${year}-${str.slice(2, 4)}-${str.slice(4, 6)}T${str.slice(6, 8)}:${str.slice(8, 10)}:${str.slice(10, 12)}Z`;
    return iso;
  }
  if (node.tag === 0x18) {
    // GeneralizedTime: YYYYMMDDHHMMSSZ
    const iso = `${str.slice(0, 4)}-${str.slice(4, 6)}-${str.slice(6, 8)}T${str.slice(8, 10)}:${str.slice(10, 12)}:${str.slice(12, 14)}Z`;
    return iso;
  }
  return null;
}

function extractDistinguishedName(nameSeqNode) {
  const attrs = {};
  if (!nameSeqNode || !nameSeqNode.children) return attrs;
  for (const rdnSet of nameSeqNode.children) {
    if (!rdnSet.children) continue;
    for (const atv of rdnSet.children) {
      if (!atv.children || atv.children.length < 2) continue;
      const oid = decodeOid(atv.children[0].content);
      const val = utf8Decoder.decode(atv.children[1].content);
      const key = OID_MAP[oid] || oid;
      attrs[key] = val;
    }
  }
  return attrs;
}

function findOcspUrls(node, found = []) {
  if (!node || !node.children) return found;
  if (
    node.children.length >= 2 &&
    node.children[0].tag === 0x06 &&
    OID_MAP[decodeOid(node.children[0].content)] === 'OCSP' &&
    node.children[1].tag === 0x86
  ) {
    const url = utf8Decoder.decode(node.children[1].content);
    if (url.startsWith('http')) found.push(url);
  }
  for (const child of node.children) {
    findOcspUrls(child, found);
  }
  return found;
}

/**
 * Giải mã chứng chỉ X.509 ở dạng nhị phân DER.
 * @param {Uint8Array} derBytes
 */
export function parseX509Certificate(derBytes) {
  try {
    const root = parseAsn1(derBytes);
    if (!root.length || !root[0].children || root[0].children.length < 2) {
      return null;
    }
    const certSeq = root[0];
    const tbs = certSeq.children[0];
    const sigAlgSeq = certSeq.children[1];
    if (!tbs.children || tbs.children.length < 6) return null;

    // Nếu có trường Version [0] explicit (tag 0xa0), các chỉ mục dịch sang phải 1
    const hasExplicitVersion = tbs.children[0].tag === 0xa0;
    const base = hasExplicitVersion ? 1 : 0;

    const serialNode = tbs.children[base];
    const issuerNode = tbs.children[base + 2];
    const validityNode = tbs.children[base + 3];
    const subjectNode = tbs.children[base + 4];

    const serialHex = Array.from(serialNode.content)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')
      .toUpperCase();

    const issuer = extractDistinguishedName(issuerNode);
    const subject = extractDistinguishedName(subjectNode);

    let notBefore = null;
    let notAfter = null;
    if (validityNode && validityNode.children && validityNode.children.length >= 2) {
      notBefore = parseAsn1Time(validityNode.children[0]);
      notAfter = parseAsn1Time(validityNode.children[1]);
    }

    let signatureAlgorithm = 'Unknown';
    if (sigAlgSeq.children && sigAlgSeq.children[0] && sigAlgSeq.children[0].tag === 0x06) {
      const oid = decodeOid(sigAlgSeq.children[0].content);
      signatureAlgorithm = OID_MAP[oid] || oid;
    }

    // Quét extensions [3] (tag 0xa3) để lấy URL OCSP của Apple
    const ocspUrls = [];
    for (const child of tbs.children) {
      if (child.tag === 0xa3) {
        // Bên trong [3] là OCTET STRING bọc các extension SEQUENCE
        const extSeqs = parseAsn1(child.content);
        for (const extSeq of extSeqs) {
          if (!extSeq.children) continue;
          for (const ext of extSeq.children) {
            if (!ext.children) continue;
            for (const sub of ext.children) {
              if (sub.tag === 0x04) {
                const inner = parseAsn1(sub.content);
                inner.forEach((n) => findOcspUrls(n, ocspUrls));
              }
            }
          }
        }
      }
    }

    const now = Date.now();
    const expMs = notAfter ? Date.parse(notAfter) : NaN;
    const isExpired = !Number.isNaN(expMs) && expMs < now;

    return {
      commonName: subject.CN || '(Không rõ CN)',
      organization: subject.O || null,
      teamUnit: subject.OU || null,
      country: subject.C || null,
      issuerCommonName: issuer.CN || '(Không rõ Issuer)',
      issuerOrganization: issuer.O || null,
      serialNumber: serialHex,
      signatureAlgorithm,
      notBefore,
      notAfter,
      isExpired,
      ocspUrls
    };
  } catch {
    return null;
  }
}

/**
 * Giải mã tệp embedded.mobileprovision bên trong gói .app.
 * @param {Uint8Array} mobileprovisionBytes
 */
export function parseMobileProvision(mobileprovisionBytes) {
  if (!mobileprovisionBytes || mobileprovisionBytes.length < 64) {
    return null;
  }

  // Tìm phần XML Plist nằm bên trong cấu trúc CMS/PKCS#7 SignedData
  const rawLatin = latin1Decoder.decode(mobileprovisionBytes);
  const xmlStart = rawLatin.indexOf('<?xml');
  const plistStart = xmlStart >= 0 ? xmlStart : rawLatin.indexOf('<plist');
  const plistEndIdx = rawLatin.lastIndexOf('</plist>');

  if (plistStart < 0 || plistEndIdx < plistStart) {
    throw new Error('Không tìm thấy cấu trúc XML Plist trong embedded.mobileprovision');
  }

  const xmlSlice = mobileprovisionBytes.subarray(plistStart, plistEndIdx + 8);
  const xmlText = utf8Decoder.decode(xmlSlice);
  const plist = parseXmlPlist(xmlText);
  if (!plist || typeof plist !== 'object') {
    throw new Error('Không thể giải mã nội dung Plist của embedded.mobileprovision');
  }

  const entitlements = plist.Entitlements || {};
  const provisionedDevices = Array.isArray(plist.ProvisionedDevices)
    ? plist.ProvisionedDevices
    : [];
  const provisionsAllDevices = Boolean(plist.ProvisionsAllDevices);
  const getTaskAllow = Boolean(entitlements['get-task-allow']);
  const isFreePersonalCandidate =
    getTaskAllow &&
    typeof plist.TimeToLive === 'number' &&
    plist.TimeToLive <= 7;

  let distributionType = 'App Store Distribution';
  let supportsOTA = false;

  if (provisionsAllDevices) {
    distributionType = 'Enterprise (In-House)';
    supportsOTA = true;
  } else if (getTaskAllow) {
    distributionType = isFreePersonalCandidate
      ? 'Development (Apple Personal Team – Hạn 7 ngày)'
      : 'Apple Development';
    supportsOTA = false; // installd từ chối cài Development qua itms-services:// nếu thiếu luồng chuyên biệt/Ad-Hoc
  } else if (provisionedDevices.length > 0) {
    distributionType = 'Ad-Hoc Distribution';
    supportsOTA = true;
  }

  const rawCerts = Array.isArray(plist.DeveloperCertificates)
    ? plist.DeveloperCertificates
    : [];
  const certificates = rawCerts
    .map((c) => (c instanceof Uint8Array ? parseX509Certificate(c) : null))
    .filter(Boolean);

  const now = Date.now();
  const expMs = plist.ExpirationDate ? Date.parse(plist.ExpirationDate) : NaN;
  const daysRemaining = Number.isNaN(expMs)
    ? null
    : Math.ceil((expMs - now) / (1000 * 60 * 60 * 24));
  const isExpired = !Number.isNaN(expMs) && expMs < now;

  return {
    name: plist.Name || null,
    uuid: plist.UUID || null,
    appIdName: plist.AppIDName || null,
    teamName: plist.TeamName || null,
    teamIdentifiers: Array.isArray(plist.TeamIdentifier) ? plist.TeamIdentifier : [],
    appIdPrefixes: Array.isArray(plist.ApplicationIdentifierPrefix)
      ? plist.ApplicationIdentifierPrefix
      : [],
    creationDate: plist.CreationDate || null,
    expirationDate: plist.ExpirationDate || null,
    timeToLiveDays: plist.TimeToLive ?? null,
    daysRemaining,
    isExpired,
    distributionType,
    supportsOTA,
    getTaskAllow,
    provisionsAllDevices,
    provisionedDevicesCount: provisionedDevices.length,
    provisionedDevices,
    entitlements,
    certificates
  };
}
