"""服务层。

刻意不在这里做批量 re-export：服务之间会互相引用（device → auth），
集中 re-export 会引入循环导入。需要哪个模块就显式 import 哪个。
"""
