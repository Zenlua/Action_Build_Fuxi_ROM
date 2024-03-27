#!/bin/bash

URL="$1"              # 移植包下载地址
GITHUB_ENV="$2"       # 输出环境变量
GITHUB_WORKSPACE="$3" # 工作目录

device=fuxi # 设备代号

zip_name=$(echo ${URL} | cut -d"/" -f5)        #包名，例：miui_FUXI_OS1.0.24.3.18.DEV_e208767273_14.0.zip
os_version=$(echo ${URL} | cut -d"/" -f4)      #版本号，例：OS1.0.24.3.18.DEV  
android_version=$(echo ${URL} | cut -d"_" -f5 | cut -d"." -f1) # Android 版本号, 例: 14
build_time=$(date) && build_utc=$(date -d "$build_time" +%s)   # 构建时间

sudo timedatectl set-timezone Asia/Shanghai
sudo apt-get remove -y firefox zstd
sudo apt-get install python3 aria2
sudo chmod -R 777 "$GITHUB_WORKSPACE"/tools

magiskboot="$GITHUB_WORKSPACE"/tools/magiskboot
ksud="$GITHUB_WORKSPACE"/tools/ksud
a7z="$GITHUB_WORKSPACE"/tools/7zzs
zstd="$GITHUB_WORKSPACE"/tools/zstd
payload_extract="$GITHUB_WORKSPACE"/tools/payload_extract
erofs_extract="$GITHUB_WORKSPACE"/tools/extract.erofs
erofs_mkfs="$GITHUB_WORKSPACE"/tools/mkfs.erofs
vbmeta="$GITHUB_WORKSPACE"/tools/vbmeta-disable-verification
lpmake="$GITHUB_WORKSPACE"/tools/lpmake
apktool_jar="java -jar "$GITHUB_WORKSPACE"/tools/apktool.jar"

Red='\033[1;31m'    # 粗体红色
Yellow='\033[1;33m' # 粗体黄色
Blue='\033[1;34m'   # 粗体蓝色
Green='\033[1;32m'  # 粗体绿色

Start_Time() {
  Start_ns=$(date +'%s%N')
}

End_Time() {
  local End_ns time
  End_ns=$(date +'%s%N')
  time=$(expr $End_ns - $Start_ns)
  [[ -z "$time" ]] && return 0

  local s ms ns h min
  ns=${time:0-9}
  s=${time%$ns}

  if [[ $s -ge 10800 ]]; then
    echo -e "${Green}- 本次$1用时: ${Blue}少于100毫秒"
  elif [[ $s -ge 3600 ]]; then
    ms=$(expr $ns / 1000000)
    h=$(expr $s / 3600)
    s=$(expr $s % 3600)
    [[ $s -ge 60 ]] && {
      min=$(expr $s / 60)
      s=$(expr $s % 60)
    }
    echo -e "${Green}- 本次$1用时: ${Blue}$h小时$min分$s秒$ms毫秒"
  elif [[ $s -ge 60 ]]; then
    ms=$(expr $ns / 1000000)
    min=$(expr $s / 60)
    s=$(expr $s % 60)
    echo -e "${Green}- 本次$1用时: ${Blue}$min分$s秒$ms毫秒"
  elif [[ -n $s ]]; then
    ms=$(expr $ns / 1000000)
    echo -e "${Green}- 本次$1用时: ${Blue}$s秒$ms毫秒"
  else
    ms=$(expr $ns / 1000000)
    echo -e "${Green}- 本次$1用时: ${Blue}$ms毫秒"
  fi
}

### 系统包下载
echo -e "${Red}- 开始下载系统包"
Start_Time
if [ ! -f "$GITHUB_WORKSPACE/${zip_name}" ]; then
    # 系统包不存在，则执行下载
    aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$URL"
else
    echo "系统包已存在，无需下载"
fi
End_Time 下载系统包
### 系统包下载结束

### 解包
echo -e "${Red}- 准备解包"
mkdir -p "$GITHUB_WORKSPACE"/Extra_dir
mkdir -p "$GITHUB_WORKSPACE"/"${device}" #底包payload.bin存放目录
mkdir -p "$GITHUB_WORKSPACE"/images/config #移植包product,system,system_ext存放目录（images）
mkdir -p "$GITHUB_WORKSPACE"/zip

echo -e "${Yellow}- 开始解包"
Start_Time
$a7z x "$GITHUB_WORKSPACE"/${zip_name} -o"$GITHUB_WORKSPACE"/"${device}" payload.bin >/dev/null
echo -e "${Red}- 开始解payload"
$payload_extract -s -o "$GITHUB_WORKSPACE"/Extra_dir/ -i "$GITHUB_WORKSPACE"/"${device}"/payload.bin -x -T0
for i in product system system_ext; do
  echo -e "${Red}- 开始转移${i}"
  sudo mv -f "$GITHUB_WORKSPACE"/Extra_dir/$i.img "$GITHUB_WORKSPACE"/images/
done

echo -e "${Red}- 转移完成，开始删除原包"
rm -rf "$GITHUB_WORKSPACE"/${zip_name} #删除原包
End_Time 

echo -e "${Red}- 开始第一次分解image"
for i in mi_ext odm system_dlkm vendor vendor_dlkm; do
  echo -e "${Yellow}- 正在分解image: $i.img"
  cd "$GITHUB_WORKSPACE"/"${device}"
  sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/Extra_dir/$i.img -x
  rm -rf "$GITHUB_WORKSPACE"/Extra_dir/$i.img
done

sudo mkdir -p "$GITHUB_WORKSPACE"/"${device}"/firmware-update/
sudo cp -rf "$GITHUB_WORKSPACE"/Extra_dir/* "$GITHUB_WORKSPACE"/"${device}"/firmware-update/ #底包mi_ext odm system_dlkm vendor vendor_dlkm存放目录
cd "$GITHUB_WORKSPACE"/images
echo -e "${Red}- 开始第二次分解image"
for i in product system system_ext; do
  echo -e "${Yellow}- 正在分解: $i"
  sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/images/$i.img -x
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done
### 解包结束

### 写入变量

echo -e "${Red}- 开始写入变量"
# 构建日期
echo "build_time=$build_time" >>$GITHUB_ENV
echo -e "${Blue}- 构建日期: $build_time"
# 包版本
echo "os_version=$os_version" >>$GITHUB_ENV
echo -e "${Blue}- 移植包版本: $os_version"
# 包安全补丁
system_build_prop=$(find "$GITHUB_WORKSPACE"/images/system/system/ -maxdepth 1 -type f -name "build.prop" | head -n 1)
security_patch=$(grep "ro.build.version.security_patch=" "$system_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- 包安全补丁版本: $security_patch"
echo "security_patch=$security_patch" >>$GITHUB_ENV
# 包基线版本
base_line=$(grep "ro.system.build.id=" "$system_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- 包基线版本: $base_line"
echo "base_line=$base_line" >>$GITHUB_ENV

### 写入变量结束

### 功能修复
echo -e "${Red}- 开始功能修复"
Start_Time

# 添加 KernelSU 支持 (可选择)
echo -e "${Red}- 添加 KernelSU 支持 (可选择)"
mkdir -p "$GITHUB_WORKSPACE"/init_boot
cd "$GITHUB_WORKSPACE"/init_boot
cp -f "$GITHUB_WORKSPACE"/"${device}"/firmware-update/init_boot.img "$GITHUB_WORKSPACE"/init_boot/
$ksud boot-patch -b "$GITHUB_WORKSPACE"/init_boot/init_boot.img --magiskboot $magiskboot --kmi android14-5.15
mv -f "$GITHUB_WORKSPACE"/init_boot/kernelsu_boot*.img "$GITHUB_WORKSPACE"/"${device}"/firmware-update/init_boot-kernelsu.img
rm -rf "$GITHUB_WORKSPACE"/init_boot

# 统一 build.prop
echo -e "${Red}- 统一 build.prop"
sudo sed -i 's/ro.build.user=[^*]*/ro.build.user=Prume/' "$GITHUB_WORKSPACE"/images/system/system/build.prop
for port_build_prop in $(sudo find "$GITHUB_WORKSPACE"/images/ -type f -name "build.prop"); do
  sudo sed -i 's/build.date=[^*]*/build.date='"$build_time"'/' "$port_build_prop"
  sudo sed -i 's/build.date.utc=[^*]*/build.date.utc='"$build_utc"'/' "$port_build_prop"
  sudo sed -i 's/persist.device_config.mglru_native.lru_gen_config=[^*]*/persist.device_config.mglru_native.lru_gen_config=all/' "$port_build_prop"
done
for vendor_build_prop in $(sudo find "$GITHUB_WORKSPACE"/"${device}"/ -type f -name "*build.prop"); do
  sudo sed -i 's/build.date=[^*]*/build.date='"$build_time"'/' "$vendor_build_prop"
  sudo sed -i 's/build.date.utc=[^*]*/build.date.utc='"$build_utc"'/' "$vendor_build_prop"
  sudo sed -i 's/ro.mi.os.version.incremental=[^*]*/ro.mi.os.version.incremental='"$os_version"'/' "$vendor_build_prop"
done

# 精简部分应用
echo -e "${Red}- 精简部分应用"
apps=("MIGalleryLockscreen" "MIUIDriveMode" "MIUIDuokanReader" "MIUIGameCenter" "MIUINewHomeMIUI15" "MIUINewHome" "MIUIYoupin" "MIUIHuanJi" "MIUIMiDrive" "MIUIVirtualSim" "ThirdAppAssistant" "XMRemoteController" "MIUIVipAccount" "MiuiScanner" "Xinre" "SmartHome" "MiShop" "MiRadio" "MIUICompass" "MediaEditor" "BaiduIME" "iflytek.inputmethod" "MIService" "MIUIEmail" "MIUIVideo" "MIUIMusicT")
for app in "${apps[@]}"; do
  appsui=$(sudo find "$GITHUB_WORKSPACE"/images/product/data-app/ -type d -iname "*${app}*")
  if [[ -n $appsui ]]; then
    echo -e "${Yellow}- 找到精简目录: $appsui"
    sudo rm -rf "$appsui"
  fi
done

# 占位广告应用
echo -e "${Red}- 占位广告应用"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/app/MSA/*
sudo cp -f "$GITHUB_WORKSPACE"/"${device}"_files/MSA.apk "$GITHUB_WORKSPACE"/images/product/app/MSA

# 替换完美图标
echo -e "${Red}- 替换完美图标"
cd "$GITHUB_WORKSPACE"
git clone https://github.com/pzcn/Perfect-Icons-Completion-Project.git icons --depth 1
for pkg in "$GITHUB_WORKSPACE"/images/product/media/theme/miui_mod_icons/dynamic/*; do
  if [[ -d "$GITHUB_WORKSPACE"/icons/icons/$pkg ]]; then
    rm -rf "$GITHUB_WORKSPACE"/icons/icons/$pkg
  fi
done
rm -rf "$GITHUB_WORKSPACE"/icons/icons/com.xiaomi.scanner
mv "$GITHUB_WORKSPACE"/images/product/media/theme/default/icons "$GITHUB_WORKSPACE"/images/product/media/theme/default/icons.zip
rm -rf "$GITHUB_WORKSPACE"/images/product/media/theme/default/dynamicicons
mkdir -p "$GITHUB_WORKSPACE"/icons/res
mv "$GITHUB_WORKSPACE"/icons/icons "$GITHUB_WORKSPACE"/icons/res/drawable-xxhdpi
cd "$GITHUB_WORKSPACE"/icons
zip -qr "$GITHUB_WORKSPACE"/images/product/media/theme/default/icons.zip res
cd "$GITHUB_WORKSPACE"/icons/themes/Hyper/
zip -qr "$GITHUB_WORKSPACE"/images/product/media/theme/default/dynamicicons.zip layer_animating_icons
cd "$GITHUB_WORKSPACE"/icons/themes/common/
zip -qr "$GITHUB_WORKSPACE"/images/product/media/theme/default/dynamicicons.zip layer_animating_icons
mv "$GITHUB_WORKSPACE"/images/product/media/theme/default/icons.zip "$GITHUB_WORKSPACE"/images/product/media/theme/default/icons
mv "$GITHUB_WORKSPACE"/images/product/media/theme/default/dynamicicons.zip "$GITHUB_WORKSPACE"/images/product/media/theme/default/dynamicicons
rm -rf "$GITHUB_WORKSPACE"/icons

#去除avb2.0校验
for i in  vbmeta.img vbmeta_system.img; do
  echo -e "${Red}- 正在去 "$i" avb2.0校验"
  sudo $vbmeta "$GITHUB_WORKSPACE"/Extra_dir/"$i"
done

# 常规修改
echo -e "${Red}- 常规修改"
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"/vendor/recovery-from-boot.p
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"/vendor/bin/install-recovery.sh

# 修复 init 崩溃
echo -e "${Red}- 修复 init 崩溃"
sudo sed -i "/start qti-testscripts/d" "$GITHUB_WORKSPACE"/"${device}"/vendor/etc/init/hw/init.qcom.rc

# 内置 TWRP
echo -e "${Red}- 内置 TWRP"
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/recovery.zip -d "$GITHUB_WORKSPACE"/"${device}"/firmware-update/

# 添加刷机脚本
echo -e "${Red}- 添加刷机脚本"
sudo unzip -o -q "$GITHUB_WORKSPACE"/tools/flashtools.zip -d "$GITHUB_WORKSPACE"/images

# 移除 Android 签名校验
sudo mkdir -p "$GITHUB_WORKSPACE"/apk/
echo -e "${Red}- 移除 Android 签名校验"
sudo cp -rf "$GITHUB_WORKSPACE"/images/system/system/framework/services.jar "$GITHUB_WORKSPACE"/apk/services.apk
cd "$GITHUB_WORKSPACE"/apk
sudo $apktool_jar d -q "$GITHUB_WORKSPACE"/apk/services.apk
fbynr='getMinimumSignatureSchemeVersionForTargetSdk'
sudo find "$GITHUB_WORKSPACE"/apk/services/smali_classes2/com/android/server/pm/ "$GITHUB_WORKSPACE"/apk/services/smali_classes2/com/android/server/pm/pkg/parsing/ -type f -maxdepth 1 -name "*.smali" -exec grep -H "$fbynr" {} \; | cut -d ':' -f 1 | while read -r i; do
  hs=$(grep -n "$fbynr" "$i" | cut -d ':' -f 1)
  sz=$(sudo tail -n +"$hs" "$i" | grep -m 1 "move-result" | tr -dc '0-9')
  hs1=$(sudo awk -v HS=$hs 'NR>=HS && /move-result /{print NR; exit}' "$i")
  hss=$hs
  sedsc="const/4 v${sz}, 0x0"
  { sudo sed -i "${hs},${hs1}d" "$i" && sudo sed -i "${hss}i\\${sedsc}" "$i"; } && echo -e "${Yellow}- ${i} 修改成功"
done
cd "$GITHUB_WORKSPACE"/apk/services/
sudo $apktool_jar b -q -f -c "$GITHUB_WORKSPACE"/apk/services/ -o services.jar
sudo cp -rf "$GITHUB_WORKSPACE"/apk/services/services.jar "$GITHUB_WORKSPACE"/images/system/system/framework/services.jar

# 替换更改文件/删除多余文件
echo -e "${Red}- 替换更改文件/删除多余文件"
sudo cp -r "$GITHUB_WORKSPACE"/"${device}"/* "$GITHUB_WORKSPACE"/images #（将设备 ${device} 目录下的所有文件和文件夹，包括子目录中的内容，复制到 $GITHUB_WORKSPACE/images 目录中。）
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"_files
End_Time 功能修复
### 功能修复结束

### 生成 super.img
echo -e "${Red}- 开始打包super.img"
Start_Time
partitions=("mi_ext" "odm" "product" "system" "system_ext" "system_dlkm" "vendor" "vendor_dlkm")
for partition in "${partitions[@]}"; do
  echo -e "${Red}- 正在生成: $partition"
  sudo python3 "$GITHUB_WORKSPACE"/tools/fspatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config
  sudo python3 "$GITHUB_WORKSPACE"/tools/contextpatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts
  sudo $erofs_mkfs --quiet -zlz4hc,9 -T 1230768000 --mount-point /$partition --fs-config-file "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config --file-contexts "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts "$GITHUB_WORKSPACE"/images/$partition.img "$GITHUB_WORKSPACE"/images/$partition
  eval "${partition}_size=$(du -sb "$GITHUB_WORKSPACE"/images/$partition.img | awk '{print $1}')"
  sudo rm -rf "$GITHUB_WORKSPACE"/images/$partition
done
sudo rm -rf "$GITHUB_WORKSPACE"/images/config
$lpmake --metadata-size 65536 --super-name super --block-size 4096 --partition mi_ext_a:readonly:"$mi_ext_size":qti_dynamic_partitions_a --image mi_ext_a="$GITHUB_WORKSPACE"/images/mi_ext.img --partition mi_ext_b:readonly:0:qti_dynamic_partitions_b --partition odm_a:readonly:"$odm_size":qti_dynamic_partitions_a --image odm_a="$GITHUB_WORKSPACE"/images/odm.img --partition odm_b:readonly:0:qti_dynamic_partitions_b --partition product_a:readonly:"$product_size":qti_dynamic_partitions_a --image product_a="$GITHUB_WORKSPACE"/images/product.img --partition product_b:readonly:0:qti_dynamic_partitions_b --partition system_a:readonly:"$system_size":qti_dynamic_partitions_a --image system_a="$GITHUB_WORKSPACE"/images/system.img --partition system_b:readonly:0:qti_dynamic_partitions_b --partition system_ext_a:readonly:"$system_ext_size":qti_dynamic_partitions_a --image system_ext_a="$GITHUB_WORKSPACE"/images/system_ext.img --partition system_ext_b:readonly:0:qti_dynamic_partitions_b --partition system_dlkm_a:readonly:"$system_dlkm_size":qti_dynamic_partitions_a --image system_dlkm_a="$GITHUB_WORKSPACE"/images/system_dlkm.img --partition system_dlkm_b:readonly:0:qti_dynamic_partitions_b --partition vendor_a:readonly:"$vendor_size":qti_dynamic_partitions_a --image vendor_a="$GITHUB_WORKSPACE"/images/vendor.img --partition vendor_b:readonly:0:qti_dynamic_partitions_b --partition vendor_dlkm_a:readonly:"$vendor_dlkm_size":qti_dynamic_partitions_a --image vendor_dlkm_a="$GITHUB_WORKSPACE"/images/vendor_dlkm.img --partition vendor_dlkm_b:readonly:0:qti_dynamic_partitions_b --device super:8321499136 --metadata-slots 3 --group qti_dynamic_partitions_a:8321499136 --group qti_dynamic_partitions_b:8321499136 --virtual-ab -F --output "$GITHUB_WORKSPACE"/images/super.img
End_Time 打包super
for i in mi_ext odm product system system_ext system_dlkm vendor vendor_dlkm; do
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done
### 生成 super.img 结束

### 输出卡刷包
echo -e "${Red}- 开始生成卡刷包"
echo -e "${Red}- 开始压缩super.zst"
Start_Time
sudo find "$GITHUB_WORKSPACE"/images/ -exec touch -t 200901010000.00 {} \;
zstd -12 -f "$GITHUB_WORKSPACE"/images/super.img -o "$GITHUB_WORKSPACE"/images/super.zst --rm
End_Time 压缩super.zst
# 生成卡刷包
echo -e "${Red}- 生成卡刷包"
Start_Time
sudo $a7z a "$GITHUB_WORKSPACE"/zip/miui_${device}_${os_version}.zip "$GITHUB_WORKSPACE"/images/* >/dev/null
sudo rm -rf "$GITHUB_WORKSPACE"/images
End_Time 压缩卡刷包
# 定制 ROM 包名
echo -e "${Red}- 定制 ROM 包名"
md5=$(md5sum "$GITHUB_WORKSPACE"/zip/miui_${device}_${os_version}.zip)
echo "MD5=${md5:0:32}" >>$GITHUB_ENV
zip_md5=${md5:0:10}
rom_name="miui_FUXI_${os_version}_${zip_md5}_${android_version}.0_Prume.zip"
sudo mv "$GITHUB_WORKSPACE"/zip/miui_${device}_${os_version}.zip "$GITHUB_WORKSPACE"/zip/"${rom_name}"
echo "rom_name=$rom_name" >>$GITHUB_ENV
### 输出卡刷包结束