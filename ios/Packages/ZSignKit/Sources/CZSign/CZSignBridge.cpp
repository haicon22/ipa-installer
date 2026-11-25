#include "include/CZSign.h"
#include "common.h"
#include "macho.h"
#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include "certcheck.h"
#include "mach-o.h"

#include <mutex>
#include <cstring>

namespace {

std::mutex g_zsign_mutex;

void write_err(char* buf, uint32_t buf_size, const char* msg) {
    if (!buf || buf_size == 0) return;
    if (!msg) {
        buf[0] = '\0';
        return;
    }
    std::snprintf(buf, buf_size, "%s", msg);
}

uint32_t read_u32_be(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

uint32_t read_u32_le(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

int verify_macho_code_signature_internal(
    const std::string& machoPath,
    bool requireCMS,
    char* errorBuf,
    uint32_t errorBufSize
) {
    std::string data;
    if (!ZFile::ReadFile(machoPath.c_str(), data) || data.size() < 64) {
        write_err(errorBuf, errorBufSize, "Không đọc được tệp thực thi Mach-O sau khi ký.");
        return -10;
    }

    const auto* bytes = reinterpret_cast<const uint8_t*>(data.data());
    size_t sliceOffset = 0;
    uint32_t magicBE = read_u32_be(bytes);

    if (magicBE == 0xCAFEBABE) {
        uint32_t nfat = read_u32_be(bytes + 4);
        if (nfat < 1 || 8 + size_t(nfat) * 20 > data.size()) {
            write_err(errorBuf, errorBufSize, "Cấu trúc Fat Mach-O đầu ra không hợp lệ.");
            return -11;
        }
        sliceOffset = read_u32_be(bytes + 8 + 8);
    }

    if (sliceOffset + 32 > data.size()) {
        write_err(errorBuf, errorBufSize, "Lát cắt Mach-O vượt kích thước tệp.");
        return -12;
    }

    uint32_t sliceMagic = read_u32_be(bytes + sliceOffset);
    bool is64 = (sliceMagic == 0xCFFAEDFE || sliceMagic == 0xFEEDFACF);
    bool le = (sliceMagic == 0xCFFAEDFE || sliceMagic == 0xCEFAEDFE);
    if (!is64 && sliceMagic != 0xCEFAEDFE && sliceMagic != 0xFEEDFACE) {
        write_err(errorBuf, errorBufSize, "Header Mach-O đầu ra không hợp lệ.");
        return -13;
    }

    auto r32 = [&](size_t off) -> uint32_t {
        return le ? read_u32_le(bytes + off) : read_u32_be(bytes + off);
    };

    uint32_t ncmds = r32(sliceOffset + 16);
    uint32_t sizeofcmds = r32(sliceOffset + 20);
    size_t cmdPos = sliceOffset + (is64 ? 32 : 28);
    size_t cmdEnd = std::min(data.size(), cmdPos + sizeofcmds);

    uint32_t csOff = 0;
    uint32_t csSize = 0;
    for (uint32_t i = 0; i < ncmds && cmdPos + 8 <= cmdEnd; ++i) {
        uint32_t cmd = r32(cmdPos);
        uint32_t cmdsize = r32(cmdPos + 4);
        if (cmdsize < 8 || cmdPos + cmdsize > cmdEnd) break;
        if (cmd == 0x1D && cmdsize >= 16) { // LC_CODE_SIGNATURE
            csOff = r32(cmdPos + 8);
            csSize = r32(cmdPos + 12);
            break;
        }
        cmdPos += cmdsize;
    }

    if (csSize < 16 || sliceOffset + csOff + csSize > data.size()) {
        write_err(errorBuf, errorBufSize, "Không tìm thấy LC_CODE_SIGNATURE hợp lệ trong nhị phân sau khi ký.");
        return -14;
    }

    const uint8_t* sb = bytes + sliceOffset + csOff;
    if (read_u32_be(sb) != 0xFADE0CC0) { // CSMAGIC_EMBEDDED_SIGNATURE
        write_err(errorBuf, errorBufSize, "Thiếu SuperBlob CSMAGIC_EMBEDDED_SIGNATURE.");
        return -15;
    }

    uint32_t blobCount = read_u32_be(sb + 8);
    bool hasCodeDir = false;
    bool hasCMS = false;

    for (uint32_t i = 0; i < blobCount; ++i) {
        size_t idxOff = 12 + size_t(i) * 8;
        if (idxOff + 8 > csSize) break;
        uint32_t slot = read_u32_be(sb + idxOff);
        uint32_t rel = read_u32_be(sb + idxOff + 4);
        if (rel + 8 > csSize) continue;
        uint32_t bMagic = read_u32_be(sb + rel);
        uint32_t bLen = read_u32_be(sb + rel + 4);
        if (bMagic == 0xFADE0C02 && bLen >= 44) {
            hasCodeDir = true;
        }
        if ((bMagic == 0xFADE0B01 || slot == 0x10000) && bLen > 8) {
            hasCMS = true;
        }
    }

    if (!hasCodeDir) {
        write_err(errorBuf, errorBufSize, "Chữ ký đầu ra thiếu bảng băm CSMAGIC_CODEDIRECTORY.");
        return -16;
    }
    if (requireCMS && !hasCMS) {
        write_err(errorBuf, errorBufSize, "Chữ ký chứng chỉ thiếu khối CMS PKCS#7.");
        return -17;
    }
    return 0;
}

} // namespace

extern "C" int czsign_verify_macho_signature(
    const char* macho_path,
    int require_cms_blob,
    char* error_buf,
    uint32_t error_buf_size
) {
    if (!macho_path || macho_path[0] == '\0') {
        write_err(error_buf, error_buf_size, "Đường dẫn Mach-O rỗng.");
        return -1;
    }
    return verify_macho_code_signature_internal(
        std::string(macho_path),
        require_cms_blob != 0,
        error_buf,
        error_buf_size
    );
}

extern "C" int czsign_check_certificate(
    const char* file_path,
    const char* password
) {
    std::lock_guard<std::mutex> lock(g_zsign_mutex);
    ZLog::SetLogLever(ZLog::E_NONE);
    if (!file_path || file_path[0] == '\0') {
        return -1;
    }
    std::string pathStr(file_path);
    std::string pwdStr(password ? password : "");
    return CheckCertificate(pathStr, pwdStr);
}

extern "C" int czsign_sign_ipa(
    const czsign_options_t* options,
    char* error_buf,
    uint32_t error_buf_size
) {
    std::lock_guard<std::mutex> lock(g_zsign_mutex);
    ZLog::SetLogLever(ZLog::E_ERROR);

    if (!options || !options->input_ipa_path || !options->output_ipa_path) {
        write_err(error_buf, error_buf_size, "Tham số đầu vào hoặc đầu ra của ZSign bị thiếu.");
        return -1;
    }

    const bool bAdhoc = (options->adhoc_sign != 0);
    std::string strInput(options->input_ipa_path);
    std::string strOutput(options->output_ipa_path);
    std::string strCertFile;
    std::string strPKeyFile(options->p12_path ? options->p12_path : "");
    std::string strProvFile(options->mobileprovision_path ? options->mobileprovision_path : "");
    std::string strEntitleFile;
    std::string strPassword(options->p12_password ? options->p12_password : "");
    std::string strBundleId(options->custom_bundle_id ? options->custom_bundle_id : "");
    std::string strDisplayName(options->custom_display_name ? options->custom_display_name : "");
    std::string strBundleVer(options->custom_bundle_version ? options->custom_bundle_version : "");
    std::string strTempBase = (options->temp_directory_path && options->temp_directory_path[0] != '\0')
        ? std::string(options->temp_directory_path)
        : ZFile::GetTempFolder();

    int zipLevel = options->zip_level;
    if (zipLevel < 0 || zipLevel > 9) {
        zipLevel = 6;
    }

    if (!ZFile::IsFileExists(strInput.c_str())) {
        write_err(error_buf, error_buf_size, "Không tìm thấy tệp IPA đầu vào để ký.");
        return -2;
    }

    if (!bAdhoc && (strPKeyFile.empty() || strProvFile.empty())) {
        write_err(error_buf, error_buf_size, "Cần cung cấp đủ tệp .p12 và .mobileprovision khi ký bằng chứng chỉ.");
        return -3;
    }

    ZSignAsset zsa;
    if (!zsa.Init(strCertFile, strPKeyFile, strProvFile, strEntitleFile, strPassword, bAdhoc, /*bSHA256Only=*/true, /*bSingleBinary=*/false)) {
        write_err(error_buf, error_buf_size, "Khởi tạo ZSignAsset thất bại (kiểm tra lại mật khẩu .p12 hoặc định dạng .mobileprovision).");
        return -4;
    }

    ZFile::CreateFolder(strTempBase.c_str());
    std::string strWorkFolder = ZFile::GetRealPathV("%s/zsign_work_%llu", strTempBase.c_str(), ZUtil::GetMicroSecond());
    bool isZipInput = ZFile::IsZipFile(strInput.c_str());

    if (isZipInput) {
        if (!Zip::Extract(strInput.c_str(), strWorkFolder.c_str())) {
            ZFile::RemoveFolder(strWorkFolder.c_str());
            write_err(error_buf, error_buf_size, "Giải nén gói IPA đầu vào thất bại.");
            return -5;
        }
    } else {
        strWorkFolder = strInput;
    }

    ZBundle bundle;
    bundle.m_bEnableDocuments = (options->enable_documents != 0);
    bundle.m_bRemoveExtensions = (options->remove_extensions != 0);
    bundle.m_bRemoveWatchApp = (options->remove_extensions != 0);
    bundle.m_bRemoveUISupportedDevices = false;
    bundle.m_bInjectExtensions = false;

    std::vector<std::string> emptyInjectDylibs;
    std::vector<std::string> emptyRemoveDylibs;

    bool signedOK = bundle.SignFolder(
        &zsa,
        strWorkFolder,
        strBundleId,
        strBundleVer,
        strDisplayName,
        emptyInjectDylibs,
        emptyRemoveDylibs,
        /*bForce=*/true,
        /*bWeakInject=*/false,
        /*bEnableCache=*/false,
        /*bRemoveProvision=*/false
    );

    if (!signedOK || bundle.m_strAppFolder.empty()) {
        if (isZipInput) ZFile::RemoveFolder(strWorkFolder.c_str());
        write_err(error_buf, error_buf_size, "Ký đệ quy nhị phân Mach-O trong gói .app thất bại.");
        return -6;
    }

    // Tự xác minh chữ ký nhị phân chính ngay sau khi ký (Post-Sign Self-Verification)
    std::string infoPath = bundle.m_strAppFolder + "/Info.plist";
    std::string infoData;
    if (!ZFile::ReadFile(infoPath.c_str(), infoData)) {
        if (isZipInput) ZFile::RemoveFolder(strWorkFolder.c_str());
        write_err(error_buf, error_buf_size, "Không đọc được Info.plist sau khi ký để xác minh.");
        return -7;
    }
    jvalue jvInfo;
    jvInfo.read_plist(infoData);
    std::string mainExec = jvInfo["CFBundleExecutable"].as_cstr();
    if (!mainExec.empty()) {
        std::string mainBinaryPath = bundle.m_strAppFolder + "/" + mainExec;
        int verifyRc = verify_macho_code_signature_internal(
            mainBinaryPath,
            !bAdhoc,
            error_buf,
            error_buf_size
        );
        if (verifyRc != 0) {
            if (isZipInput) ZFile::RemoveFolder(strWorkFolder.c_str());
            return verifyRc;
        }
    }

    // Đóng gói lại thành .ipa hoàn chỉnh
    size_t payloadPos = bundle.m_strAppFolder.rfind("Payload");
    if (payloadPos == std::string::npos || payloadPos == 0) {
        if (isZipInput) ZFile::RemoveFolder(strWorkFolder.c_str());
        write_err(error_buf, error_buf_size, "Không tìm thấy thư mục gốc Payload để đóng gói IPA.");
        return -8;
    }

    std::string baseArchiveDir = bundle.m_strAppFolder.substr(0, payloadPos - 1);
    ZFile::RemoveFile(strOutput.c_str());
    if (!Zip::Archive(baseArchiveDir.c_str(), strOutput.c_str(), zipLevel)) {
        if (isZipInput) ZFile::RemoveFolder(strWorkFolder.c_str());
        write_err(error_buf, error_buf_size, "Đóng gói kho nén IPA đầu ra thất bại.");
        return -9;
    }

    if (isZipInput) {
        ZFile::RemoveFolder(strWorkFolder.c_str());
    }
    return 0;
}
