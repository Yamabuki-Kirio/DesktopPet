allprojects {
    repositories {
        // 国内镜像优先（Phase 4A 允许的差异之一：**只替换下载源，不改任何版本号**）。
        // 本机到 repo.maven.apache.org / dl.google.com 的大文件下载会长时间停滞，
        // 华为云镜像实测约 850KB/s；经镜像的依赖统一只读 POM 元数据，
        // 顺带避开部分 Gradle Module Metadata 里指向 github.com 的绝对地址。
        maven {
            url = uri("https://mirrors.huaweicloud.com/repository/google/")
            metadataSources {
                mavenPom()
                artifact()
            }
        }
        maven {
            url = uri("https://mirrors.huaweicloud.com/repository/maven/")
            metadataSources {
                mavenPom()
                artifact()
            }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
