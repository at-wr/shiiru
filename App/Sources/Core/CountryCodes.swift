import Foundation

struct Country: Equatable {
    let iso: String
    let dialCode: String

    var name: String {
        Locale.current.localizedString(forRegionCode: iso) ?? iso
    }

    var flag: String {
        iso.unicodeScalars.reduce(into: "") { result, scalar in
            if let flagScalar = Unicode.Scalar(0x1F1E6 + scalar.value - Unicode.Scalar("A").value) {
                result.unicodeScalars.append(flagScalar)
            }
        }
    }
}

enum CountryCodes {

    static let all: [Country] = {
        table
            .split(separator: " ")
            .map { entry -> Country in
                let parts = entry.split(separator: ":")
                return Country(iso: String(parts[0]), dialCode: String(parts[1]))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static var current: Country {
        let region = Locale.current.region?.identifier ?? "US"
        return all.first { $0.iso == region } ?? Country(iso: "US", dialCode: "1")
    }

    static func country(forDialPrefix digits: String) -> Country? {
        guard !digits.isEmpty else { return nil }
        for length in stride(from: min(4, digits.count), through: 1, by: -1) {
            let prefix = String(digits.prefix(length))
            let matches = all.filter { $0.dialCode == prefix }
            if matches.isEmpty { continue }
            if let preferred = preferredISO[prefix],
               let match = matches.first(where: { $0.iso == preferred }) {
                return match
            }
            return matches.first
        }
        return nil
    }

    private static let preferredISO: [String: String] = [
        "1": "US", "7": "RU", "44": "GB", "61": "AU", "33": "FR",
        "212": "MA", "262": "RE", "590": "GP", "596": "MQ", "47": "NO",
    ]

    static func numberPattern(forDialCode code: String) -> String {
        switch code {
        case "1": return "XXX XXX XXXX"
        case "7": return "XXX XXX XX XX"
        case "44": return "XXXX XXXXXX"
        case "49": return "XXXX XXXXXXXX"
        case "33", "34": return "XXX XXX XXX"
        case "39": return "XXX XXX XXXX"
        case "81", "82", "86": return "XXX XXXX XXXX"
        case "91": return "XXXXX XXXXX"
        case "61": return "XXX XXX XXX"
        case "55": return "XX XXXXX XXXX"
        case "852", "65": return "XXXX XXXX"
        case "971", "966": return "XX XXX XXXX"
        case "380", "375": return "XX XXX XX XX"
        case "48", "31", "32", "46", "41", "43", "30", "351", "420", "36": return "XXX XXX XXX"
        default: return "XXX XXX XXXX"
        }
    }

    static func formatInternational(_ digits: String) -> String {
        let digits = digits.filter(\.isNumber)
        guard let country = country(forDialPrefix: digits) else { return "+" + digits }
        let national = String(digits.dropFirst(country.dialCode.count))
        let formatted = format(nationalDigits: national, dialCode: country.dialCode)
        return formatted.isEmpty ? "+\(country.dialCode)" : "+\(country.dialCode) \(formatted)"
    }

    static func format(nationalDigits digits: String, dialCode: String) -> String {
        let pattern = numberPattern(forDialCode: dialCode)
        var result = ""
        var index = digits.startIndex
        for slot in pattern where index < digits.endIndex {
            if slot == "X" {
                result.append(digits[index])
                index = digits.index(after: index)
            } else {
                result.append(slot)
            }
        }
        var overflowCount = 0
        while index < digits.endIndex {
            if overflowCount.isMultiple(of: 2) { result.append(" ") }
            result.append(digits[index])
            index = digits.index(after: index)
            overflowCount += 1
        }
        return result
    }

    private static let table = """
    AF:93 AL:355 DZ:213 AS:1684 AD:376 AO:244 AI:1264 AG:1268 AR:54 AM:374 AW:297 AU:61 AT:43 AZ:994 \
    BS:1242 BH:973 BD:880 BB:1246 BY:375 BE:32 BZ:501 BJ:229 BM:1441 BT:975 BO:591 BA:387 BW:267 BR:55 \
    BN:673 BG:359 BF:226 BI:257 KH:855 CM:237 CA:1 CV:238 KY:1345 CF:236 TD:235 CL:56 CN:86 CO:57 KM:269 \
    CG:242 CD:243 CR:506 CI:225 HR:385 CU:53 CY:357 CZ:420 DK:45 DJ:253 DM:1767 DO:1809 EC:593 EG:20 \
    SV:503 GQ:240 ER:291 EE:372 SZ:268 ET:251 FJ:679 FI:358 FR:33 GF:594 PF:689 GA:241 GM:220 GE:995 \
    DE:49 GH:233 GI:350 GR:30 GL:299 GD:1473 GP:590 GU:1671 GT:502 GN:224 GW:245 GY:592 HT:509 HN:504 \
    HK:852 HU:36 IS:354 IN:91 ID:62 IR:98 IQ:964 IE:353 IL:972 IT:39 JM:1876 JP:81 JO:962 KZ:7 KE:254 \
    KI:686 KP:850 KR:82 KW:965 KG:996 LA:856 LV:371 LB:961 LS:266 LR:231 LY:218 LI:423 LT:370 LU:352 \
    MO:853 MG:261 MW:265 MY:60 MV:960 ML:223 MT:356 MH:692 MQ:596 MR:222 MU:230 MX:52 FM:691 MD:373 \
    MC:377 MN:976 ME:382 MS:1664 MA:212 MZ:258 MM:95 NA:264 NR:674 NP:977 NL:31 NC:687 NZ:64 NI:505 \
    NE:227 NG:234 NU:683 MK:389 NO:47 OM:968 PK:92 PW:680 PS:970 PA:507 PG:675 PY:595 PE:51 PH:63 PL:48 \
    PT:351 PR:1787 QA:974 RE:262 RO:40 RU:7 RW:250 KN:1869 LC:1758 VC:1784 WS:685 SM:378 ST:239 SA:966 \
    SN:221 RS:381 SC:248 SL:232 SG:65 SK:421 SI:386 SB:677 SO:252 ZA:27 SS:211 ES:34 LK:94 SD:249 SR:597 \
    SE:46 CH:41 SY:963 TW:886 TJ:992 TZ:255 TH:66 TL:670 TG:228 TO:676 TT:1868 TN:216 TR:90 TM:993 \
    TC:1649 TV:688 UG:256 UA:380 AE:971 GB:44 US:1 UY:598 UZ:998 VU:678 VA:379 VE:58 VN:84 VG:1284 \
    VI:1340 YE:967 ZM:260 ZW:263 XK:383
    """
}
