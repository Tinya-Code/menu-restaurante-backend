import { Module } from '@nestjs/common';
import { AuthService } from './auth.service';
import { AuthController } from './auth.controller';
import { DatabaseModule } from '../../config/database/database.module';
import { FirebaseModule } from '../../config/firebase/firebase.module';

@Module({
  imports: [DatabaseModule, FirebaseModule],
  controllers: [AuthController],
  providers: [AuthService],
})
export class AuthModule {}
